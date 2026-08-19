import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/band_powers.dart';
import 'package:kore/dsp/cognitive_load_index.dart';
import 'package:kore/dsp/dart_dsp_engine.dart';
import 'package:kore/dsp/load_profile.dart';
import 'package:kore/services/history_store.dart';
import 'package:kore/session/kore_history.dart';
import 'package:kore/session/kore_session.dart';
import 'package:kore/session/reset_record.dart';
import 'package:kore/sources/simulated_eeg_source.dart';

ResetRecord _rec(DateTime day, {double before = 80, double after = 55}) =>
    ResetRecord(
      startedAt: day.toUtc(),
      completed: true,
      loadBefore: before,
      loadAfter: after,
    );

DailyLoad _day(DateTime d, {int frames = 1000, double mean = 40, double? peak}) =>
    DailyLoad(
      day: DateTime(d.year, d.month, d.day),
      frames: frames,
      meanIndex: mean,
      peakIndex: peak ?? mean + 10,
    );

void main() {
  final today = DateTime(2026, 3, 14);
  DateTime daysAgo(int n) => DateTime(2026, 3, 14 - n);

  group('the daily rollup', () {
    test('two sessions on one day merge, weighted by measured time', () {
      final log = DailyLoadLog.empty
          .record(_day(today, frames: 100, mean: 20, peak: 30))
          .record(_day(today, frames: 300, mean: 60, peak: 90));

      expect(log.days, hasLength(1));
      expect(log.days.single.frames, 400);
      expect(log.days.single.meanIndex, closeTo(50.0, 1e-9),
          reason: 'a two-minute session must not weigh as much as an hour');
      expect(log.days.single.peakIndex, 90.0);
    });

    test('an empty session does not create a day', () {
      expect(DailyLoadLog.empty.record(_day(today, frames: 0)).isEmpty, isTrue);
    });

    test('the mean over a window is weighted by measured time too', () {
      final log = DailyLoadLog.empty
          .record(_day(daysAgo(1), frames: 100, mean: 20))
          .record(_day(today, frames: 300, mean: 60));

      expect(log.meanIndexOverLastDays(today, 7), closeTo(50.0, 1e-9));
      expect(log.meanIndexOverLastDays(today, 1), closeTo(60.0, 1e-9),
          reason: 'a one-day window is today only');
      expect(DailyLoadLog.empty.meanIndexOverLastDays(today, 7), isNull,
          reason: 'null rather than zero, as everywhere else in the history');
    });

    test('a climbing week reads as a climbing trend', () {
      var log = DailyLoadLog.empty;
      for (var i = 0; i < 5; i++) {
        log = log.record(_day(daysAgo(4 - i), mean: 40.0 + 2.0 * i));
      }

      expect(log.trendPerDay(today), closeTo(2.0, 1e-9));
    });

    test('a falling week reads as a falling trend', () {
      var log = DailyLoadLog.empty;
      for (var i = 0; i < 5; i++) {
        log = log.record(_day(daysAgo(4 - i), mean: 60.0 - 3.0 * i));
      }

      expect(log.trendPerDay(today), closeTo(-3.0, 1e-9));
    });

    test('two mornings are not a direction of travel', () {
      final log = DailyLoadLog.empty
          .record(_day(daysAgo(1), mean: 30))
          .record(_day(today, mean: 70));

      expect(log.trendPerDay(today), isNull,
          reason: 'two points always fit a line perfectly');
    });

    test('days with almost no measured load are excluded from the trend', () {
      var log = DailyLoadLog.empty.record(_day(daysAgo(2), mean: 30));
      // Two app-opens of a few seconds each.
      log = log.record(_day(daysAgo(1), frames: 10, mean: 90));
      log = log.record(_day(today, frames: 10, mean: 95));

      expect(log.trendPerDay(today), isNull,
          reason: 'a daily mean over twelve frames is whatever the user '
              'happened to be doing when they opened the app');
    });

    test('the log stays bounded', () {
      var log = DailyLoadLog.empty;
      for (var i = 0; i < DailyLoadLog.maxDays + 40; i++) {
        log = log.record(_day(DateTime(2026, 1, 1 + i)));
      }

      expect(log.days, hasLength(DailyLoadLog.maxDays));
      expect(log.days.last.day, DateTime(2026, 1, 1 + DailyLoadLog.maxDays + 39),
          reason: 'the oldest days are the ones dropped');
    });
  });

  group('the document on disk', () {
    late Directory dir;
    late HistoryStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('kore_v2_test');
      store = HistoryStore(File('${dir.path}/history.json'));
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('a v1 file migrates forward instead of being discarded', () async {
      // Exactly what v1 wrote: the whole file was the record array.
      await store.file.parent.create(recursive: true);
      await store.file.writeAsString(jsonEncode([
        _rec(daysAgo(2)).toJson(),
        _rec(daysAgo(1)).toJson(),
      ]));

      final loaded = await store.loadDocument();
      expect(loaded.resets.totalCount, 2,
          reason: 'those records are the user\'s streak');
      expect(loaded.profile.hasBaseline, isFalse);
      expect(loaded.days.isEmpty, isTrue);

      // The next write upgrades the file in place.
      await store.saveState(
        profile: const LoadProfile(baselineLogRatio: -1.1, sessionCount: 3),
        days: DailyLoadLog.empty.record(_day(today)),
      );

      final raw = jsonDecode(await store.file.readAsString());
      expect(raw, isA<Map>());
      expect((raw as Map)['version'], KoreHistory.formatVersion);

      final again = await store.loadDocument();
      expect(again.resets.totalCount, 2, reason: 'migration must not lose them');
      expect(again.profile.baselineLogRatio, closeTo(-1.1, 1e-9));
      expect(again.days.days, hasLength(1));
    });

    test('the profile and the daily log round-trip', () async {
      final profile = const LoadProfile(
        baselineLogRatio: 0.42,
        indexMean: 63.5,
        indexVariance: 68.0625,
        indexFrames: 9000,
        sessionCount: 14,
      );
      await store.saveState(
        profile: profile,
        days: DailyLoadLog.empty
            .record(_day(daysAgo(1), mean: 44))
            .record(_day(today, mean: 52)),
      );

      final loaded = await store.loadDocument();
      expect(loaded.profile.baselineLogRatio, closeTo(0.42, 1e-9));
      expect(loaded.profile.indexMean, closeTo(63.5, 1e-9));
      expect(loaded.profile.indexSd, closeTo(8.25, 1e-9));
      expect(loaded.profile.indexFrames, 9000);
      expect(loaded.days.days, hasLength(2));
      expect(loaded.days.latest!.meanIndex, closeTo(52.0, 1e-9));
    });

    test('appending a reset does not erase the profile beside it', () async {
      await store.saveState(
        profile: const LoadProfile(baselineLogRatio: -0.9, sessionCount: 5),
        days: DailyLoadLog.empty.record(_day(today)),
      );

      // A caller that knows nothing about profiles.
      await store.append(ResetHistory.empty, _rec(today));

      final loaded = await store.loadDocument();
      expect(loaded.resets.totalCount, 1);
      expect(loaded.profile.baselineLogRatio, closeTo(-0.9, 1e-9),
          reason: 'a session only ever owns part of the document');
      expect(loaded.days.days, hasLength(1));
    });

    test('saving state does not erase the resets beside it', () async {
      var h = ResetHistory.empty;
      h = await store.append(h, _rec(daysAgo(1)));
      h = await store.append(h, _rec(today));

      await store.saveState(
          profile: const LoadProfile(baselineLogRatio: 1.5),
          days: DailyLoadLog.empty);

      final loaded = await store.loadDocument();
      expect(loaded.resets.totalCount, 2);
      expect(loaded.resets.currentStreakDays(today), 2);
      expect(loaded.profile.baselineLogRatio, closeTo(1.5, 1e-9));
    });

    test('a corrupt file degrades to an empty document', () async {
      await store.file.parent.create(recursive: true);
      await store.file.writeAsString('{ this is not json');

      final loaded = await store.loadDocument();
      expect(loaded.resets.totalCount, 0);
      expect(loaded.profile.hasBaseline, isFalse);
      expect(loaded.days.isEmpty, isTrue);
    });

    test('a damaged half does not take the other halves with it', () async {
      await store.file.parent.create(recursive: true);
      await store.file.writeAsString(jsonEncode({
        'version': 2,
        'resets': [
          {'startedAt': 'garbage'},
          _rec(daysAgo(1)).toJson(),
        ],
        'profile': 'not a profile',
        'days': [
          {'day': 'nonsense'},
          _day(today, mean: 33).toJson(),
        ],
      }));

      final loaded = await store.loadDocument();
      expect(loaded.resets.totalCount, 1);
      expect(loaded.profile.hasBaseline, isFalse,
          reason: 'an unreadable profile costs the personalisation, and the '
              'cold-start default is always safe');
      expect(loaded.days.days, hasLength(1));
      expect(loaded.days.latest!.meanIndex, closeTo(33.0, 1e-9));
    });

    test('the reset log is still bounded with a v2 document around it',
        () async {
      var h = ResetHistory.empty;
      await store.saveState(
          profile: const LoadProfile(baselineLogRatio: 0.2),
          days: DailyLoadLog.empty);

      for (var i = 0; i < HistoryStore.maxRecords + 10; i++) {
        h = await store.append(h, _rec(daysAgo(1)));
      }

      final loaded = await store.loadDocument();
      expect(loaded.resets.totalCount, HistoryStore.maxRecords);
      expect(loaded.profile.baselineLogRatio, closeTo(0.2, 1e-9));
    });
  });

  group('the handoff between sessions', () {
    test('a profile only lands before the baseline capture begins', () {
      final cli = CognitiveLoadIndex();
      expect(cli.adoptProfile(const LoadProfile(baselineLogRatio: 1.0)), isTrue);
      expect(cli.strainEnter, CognitiveLoadIndex.kStrainEnter);

      // One frame in, the capture has started and the profile is locked.
      cli.update(const BandPowers(
          theta: 100, alpha: 100, total: 200, frameIndex: 0));
      expect(cli.adoptProfile(const LoadProfile(baselineLogRatio: -3.0)), isFalse,
          reason: 'one session must not measure against two different users');
      expect(cli.profile.baselineLogRatio, closeTo(1.0, 1e-9));
    });

    // Outside fakeAsync: file I/O completes on the real event loop. The clock
    // is pinned so no samples are generated - the index is driven directly,
    // because what is under test is what crosses the disk, not the pipeline.
    test('the next session adopts the baseline this one left behind', () async {
      final dir = await Directory.systemTemp.createTemp('kore_handoff_test');
      addTearDown(() => dir.delete(recursive: true));
      final store = HistoryStore(File('${dir.path}/history.json'));

      final first = KoreSession(
        source: SimulatedEegSource(elapsedMicros: () => 0),
        engine: DartDspEngine(),
        store: store,
      );
      await first.start();
      expect(first.loadProfile.hasBaseline, isFalse, reason: 'a new user');

      // 15 s of baseline capture at a ratio well above 1:1.
      for (var i = 0; i < 60; i++) {
        first.index.update(
            BandPowers(theta: 600, alpha: 100, total: 700, frameIndex: i));
      }
      expect(first.isCalibrated, isTrue);
      await first.flushState();
      first.dispose();

      final second = KoreSession(
        source: SimulatedEegSource(elapsedMicros: () => 0),
        engine: DartDspEngine(),
        store: store,
      );
      await second.start();

      expect(second.loadProfile.hasBaseline, isTrue,
          reason: 'the app must not meet the same user as a stranger twice');
      expect(second.loadProfile.baselineLogRatio,
          closeTo(first.loadProfile.baselineLogRatio!, 1e-9));
      expect(second.loadProfile.sessionCount, 1);
      second.dispose();
    });

    test('a session accumulates the day it measured', () {
      fakeAsync((async) {
        final session = KoreSession(
          source: SimulatedEegSource(
              elapsedMicros: () => async.elapsed.inMicroseconds),
          engine: DartDspEngine(),
        );
        session.start();
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 45));
        async.flushMicrotasks();
        expect(session.isCalibrated, isTrue);
        expect(session.dailyLoad.isEmpty, isTrue,
            reason: 'nothing is folded in until the session writes');

        session.flushState();
        async.flushMicrotasks();

        final day = session.dailyLoad.latest;
        expect(day, isNotNull);
        expect(day!.frames, greaterThan(80),
            reason: 'roughly 25 s of calibrated frames at 4 Hz');
        expect(day.meanIndex, inInclusiveRange(0.0, 100.0));
        expect(day.peakIndex, greaterThanOrEqualTo(day.meanIndex));

        // Folding twice must not count the same frames twice.
        final frames = day.frames;
        session.flushState();
        async.flushMicrotasks();
        expect(session.dailyLoad.latest!.frames, frames);

        session.dispose();
      });
    });
  });
}
