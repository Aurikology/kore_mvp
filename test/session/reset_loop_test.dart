import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/dart_dsp_engine.dart';
import 'package:kore/dsp/focus_crash_predictor.dart';
import 'package:kore/services/history_store.dart';
import 'package:kore/session/kore_session.dart';
import 'package:kore/session/reset_record.dart';
import 'package:kore/sources/simulated_eeg_source.dart';

/// End-to-end cover for the core loop in `docs/positioning.md`:
/// detect -> reset -> confirm -> reinforce.
///
/// This path used to be untestable. The simulated source counts samples from a
/// real Stopwatch, so under `flutter test` - where timers are faked but a
/// Stopwatch is not - pumping produced no samples and the index never left
/// calibration. Feeding it fakeAsync's own clock runs the whole 75 s journey
/// in about a second, and it was a bug on exactly this path (the check-in
/// being popped by the outgoing protocol sheet) that motivated writing it.
KoreSession _session({HistoryStore? store, required FakeAsync async}) =>
    KoreSession(
      source: SimulatedEegSource(
        elapsedMicros: () => async.elapsed.inMicroseconds,
      ),
      // The Dart engine, not createDspEngine(): the native library is not
      // beside the test runner, and this is not what is under test here.
      engine: DartDspEngine(),
      store: store,
    );

/// Runs the session forward, letting queued microtasks drain each step.
void _advance(FakeAsync async, Duration d) {
  async.elapse(d);
  async.flushMicrotasks();
}

void main() {
  test('calibrates, then a completed reset is recorded with its rating', () {
    fakeAsync((async) {
      final session = _session(async: async);
      session.start();
      async.flushMicrotasks();

      expect(session.isCalibrated, isFalse);

      // ~19 s: 2 s to fill the analysis window, then 15 s of baseline capture.
      _advance(async, const Duration(seconds: 25));
      expect(session.isCalibrated, isTrue,
          reason: 'the source never produced enough samples');

      // The scripted timeline has driven the load up by now.
      session.simulateStrain();
      _advance(async, const Duration(seconds: 15));
      final before = session.cognitiveLoad;
      expect(before, greaterThan(50));

      session.startReset();
      expect(session.resetActive, isTrue);
      expect(session.awaitingCheckIn, isFalse,
          reason: 'nothing to confirm until the protocol ends');

      // Let it run the full 60 s rather than cancelling.
      _advance(async, const Duration(seconds: 61));

      expect(session.resetActive, isFalse);
      expect(session.awaitingCheckIn, isTrue,
          reason: 'a completed protocol must offer the check-in');
      // Read the drop before committing - commitReset clears the pending
      // reset, so asking afterwards always answers zero.
      final drop = session.pendingDrop;
      expect(drop, greaterThan(0),
          reason: 'the guided reset should have brought the index down');

      session.commitReset(clarity: 4);
      async.flushMicrotasks();

      final history = session.resetHistory;
      expect(history.totalCount, 1);
      expect(history.completedCount, 1);
      expect(history.records.single.clarity, 4);
      expect(history.records.single.drop, closeTo(drop, 1e-9));
      expect(history.averageDrop, greaterThan(0));

      session.dispose();
    });
  });

  test('the session stays silent about crashes until it is calibrated', () {
    fakeAsync((async) {
      final session = _session(async: async);
      session.start();
      async.flushMicrotasks();

      _advance(async, const Duration(seconds: 5));
      expect(session.isCalibrated, isFalse);
      expect(session.crashWarning, isFalse);
      expect(session.crashForecast.status, CrashForecastStatus.uncalibrated,
          reason: 'a forecast over an index with no baseline is theatre');

      _advance(async, const Duration(seconds: 25));
      expect(session.isCalibrated, isTrue);
      expect(session.crashForecast.status,
          isNot(CrashForecastStatus.uncalibrated),
          reason: 'the predictor must be live once the baseline lands');

      session.recalibrate();
      expect(session.crashForecast.status, CrashForecastStatus.uncalibrated);

      session.dispose();
    });
  });

  test('a reset ended early is logged but offers no check-in', () {
    fakeAsync((async) {
      final session = _session(async: async);
      session.start();
      async.flushMicrotasks();
      _advance(async, const Duration(seconds: 25));
      expect(session.isCalibrated, isTrue);

      session.startReset();
      _advance(async, const Duration(seconds: 4));
      session.cancelReset();

      expect(session.awaitingCheckIn, isFalse,
          reason: 'asking whether a four-second abort helped collects noise');
      expect(session.hasUncommittedReset, isTrue,
          reason: 'abandonment is still a retention signal worth recording');

      session.commitReset();
      async.flushMicrotasks();

      expect(session.resetHistory.totalCount, 1);
      expect(session.resetHistory.completedCount, 0);
      expect(session.resetHistory.averageDrop, isNull,
          reason: 'an abandoned reset says nothing about effectiveness');

      session.dispose();
    });
  });

  test('a reset taken before calibration is not recorded at all', () {
    fakeAsync((async) {
      final session = _session(async: async);
      session.start();
      async.flushMicrotasks();

      // Straight in, with no baseline established.
      expect(session.isCalibrated, isFalse);
      session.startReset();
      _advance(async, const Duration(seconds: 61));

      expect(session.resetActive, isFalse);
      expect(session.hasUncommittedReset, isFalse,
          reason: 'a before/after pair with no baseline has no meaning');

      session.commitReset(clarity: 5);
      async.flushMicrotasks();
      expect(session.resetHistory.totalCount, 0);

      session.dispose();
    });
  });

  // Outside fakeAsync: file I/O completes on the real event loop, and elapsing
  // fake time does not advance it. The clock is pinned so no samples are
  // generated - this is about the store, not the pipeline.
  test('a session loads the history written by the previous run', () async {
    final dir = await Directory.systemTemp.createTemp('kore_loop_test');
    addTearDown(() => dir.delete(recursive: true));
    final store = HistoryStore(File('${dir.path}/history.json'));

    final first = KoreSession(
      source: SimulatedEegSource(elapsedMicros: () => 0),
      engine: DartDspEngine(),
      store: store,
    );
    await first.start();
    await store.append(
      first.resetHistory,
      ResetRecord(
        startedAt: DateTime.utc(2026, 8, 18, 9),
        completed: true,
        loadBefore: 80,
        loadAfter: 55,
        clarity: 5,
      ),
    );
    first.dispose();

    // A second session, as if the app had been restarted.
    final second = KoreSession(
      source: SimulatedEegSource(elapsedMicros: () => 0),
      engine: DartDspEngine(),
      store: store,
    );
    await second.start();

    expect(second.resetHistory.totalCount, 1,
        reason: 'the dashboard must show the streak before the first frame');
    expect(second.resetHistory.records.single.clarity, 5);
    expect(second.resetHistory.averageDrop, 25);
    second.dispose();
  });
}
