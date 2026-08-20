import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kore/services/history_store.dart';
import 'package:kore/session/reset_record.dart';

ResetRecord _rec(DateTime day,
        {bool completed = true, double before = 70, double after = 50, int? clarity}) =>
    ResetRecord(
      startedAt: day.toUtc(),
      completed: completed,
      loadBefore: before,
      loadAfter: after,
      clarity: clarity,
    );

void main() {
  // Fixed clock throughout: a streak test that reads DateTime.now() passes or
  // fails depending on the hour it runs at.
  final today = DateTime(2026, 3, 14);
  DateTime daysAgo(int n) => DateTime(2026, 3, 14 - n, 9);

  group('streaks', () {
    test('consecutive days count, and today is not required', () {
      // Reset yesterday and the day before, nothing yet today. The streak is
      // still alive - it breaks after a day passes empty, not at midnight.
      final h = ResetHistory([_rec(daysAgo(2)), _rec(daysAgo(1))]);
      expect(h.currentStreakDays(today), 2);
    });

    test('a gap ends the streak', () {
      final h = ResetHistory([_rec(daysAgo(5)), _rec(daysAgo(4)), _rec(daysAgo(1))]);
      expect(h.currentStreakDays(today), 1);
    });

    test('two days of silence breaks it entirely', () {
      expect(ResetHistory([_rec(daysAgo(2))]).currentStreakDays(today), 0);
    });

    test('several resets in one day count once', () {
      final h = ResetHistory([
        _rec(DateTime(2026, 3, 14, 8)),
        _rec(DateTime(2026, 3, 14, 13)),
        _rec(DateTime(2026, 3, 14, 20)),
      ]);
      expect(h.currentStreakDays(today), 1);
    });

    test('abandoned resets do not extend a streak', () {
      final h = ResetHistory([
        _rec(daysAgo(1)),
        _rec(DateTime(2026, 3, 14, 8), completed: false),
      ]);
      // Yesterday completed, today only abandoned: still 1, not 2.
      expect(h.currentStreakDays(today), 1);
    });

    test('crosses a month boundary', () {
      final march = DateTime(2026, 3, 2);
      final h = ResetHistory([
        _rec(DateTime(2026, 2, 28, 9)),
        _rec(DateTime(2026, 3, 1, 9)),
        _rec(DateTime(2026, 3, 2, 9)),
      ]);
      expect(h.currentStreakDays(march), 3);
    });

    test('empty history has no streak', () {
      expect(ResetHistory.empty.currentStreakDays(today), 0);
    });
  });

  group('aggregates', () {
    test('average drop covers completed resets only', () {
      final h = ResetHistory([
        _rec(daysAgo(1), before: 80, after: 60), // drop 20
        _rec(daysAgo(1), before: 70, after: 60), // drop 10
        // Abandoned after four seconds; says nothing about the protocol.
        _rec(daysAgo(1), before: 90, after: 89, completed: false),
      ]);
      expect(h.averageDrop, 15.0);
      expect(h.completedCount, 2);
      expect(h.totalCount, 3);
    });

    test('a reset that raised the load drags the average down honestly', () {
      final h = ResetHistory([
        _rec(daysAgo(1), before: 80, after: 60), // +20
        _rec(daysAgo(1), before: 50, after: 60), // -10
      ]);
      expect(h.averageDrop, 5.0);
    });

    test('average clarity ignores skipped check-ins', () {
      final h = ResetHistory([
        _rec(daysAgo(1), clarity: 4),
        _rec(daysAgo(1), clarity: 2),
        _rec(daysAgo(1)), // skipped
      ]);
      expect(h.averageClarity, 3.0);
    });

    test('averages are null rather than zero before any data', () {
      expect(ResetHistory.empty.averageDrop, isNull);
      expect(ResetHistory.empty.averageClarity, isNull);
    });

    test('last-7-days window is inclusive of today and excludes older', () {
      final h = ResetHistory([
        _rec(daysAgo(7)),
        _rec(daysAgo(6)),
        _rec(DateTime(2026, 3, 14, 9)),
      ]);
      expect(h.completedInLastDays(today, 7), 2);
    });
  });

  group('serialisation', () {
    test('round-trips through JSON', () {
      final original = _rec(daysAgo(1), before: 71.5, after: 48.25, clarity: 4);
      final back = ResetRecord.tryFromJson(
          jsonDecode(jsonEncode(original.toJson())));

      expect(back, isNotNull);
      expect(back!.startedAt, original.startedAt);
      expect(back.completed, isTrue);
      expect(back.loadBefore, 71.5);
      expect(back.loadAfter, 48.25);
      expect(back.clarity, 4);
    });

    test('rejects entries it cannot trust', () {
      expect(ResetRecord.tryFromJson(null), isNull);
      expect(ResetRecord.tryFromJson('nonsense'), isNull);
      expect(ResetRecord.tryFromJson({'startedAt': 'not-a-date'}), isNull);
      expect(
        ResetRecord.tryFromJson({'startedAt': '2026-03-13T09:00:00Z'}),
        isNull,
        reason: 'missing loads',
      );
      // Out-of-range self-reports are dropped to null, not clamped: a 9 means
      // the file was edited, and inventing a 5 would be worse than no answer.
      final r = ResetRecord.tryFromJson({
        'startedAt': '2026-03-13T09:00:00Z',
        'loadBefore': 70,
        'loadAfter': 50,
        'clarity': 9,
      });
      expect(r, isNotNull);
      expect(r!.clarity, isNull);
    });
  });

  group('HistoryStore', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('kore_history_test');
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    HistoryStore storeIn(Directory d) =>
        HistoryStore(File('${d.path}/history.json'));

    test('a missing file reads as empty, not as an error', () async {
      expect((await storeIn(dir).load()).totalCount, 0);
    });

    test('append then load round-trips, creating the directory', () async {
      final store = HistoryStore(File('${dir.path}/nested/deep/history.json'));
      var h = ResetHistory.empty;
      h = await store.append(h, _rec(daysAgo(1), clarity: 5));
      h = await store.append(h, _rec(DateTime(2026, 3, 14, 9)));

      final reloaded = await store.load();
      expect(reloaded.totalCount, 2);
      expect(reloaded.currentStreakDays(today), 2);
      expect(reloaded.records.first.clarity, 5);
    });

    test('a corrupt file degrades to empty instead of crashing', () async {
      final f = File('${dir.path}/history.json');
      await f.writeAsString('{ this is not json');
      expect((await storeIn(f.parent).load()).totalCount, 0);
    });

    test('one bad record does not discard the good ones', () async {
      final f = File('${dir.path}/history.json');
      await f.writeAsString(jsonEncode([
        {'startedAt': 'garbage'},
        _rec(daysAgo(1)).toJson(),
      ]));
      expect((await storeIn(f.parent).load()).totalCount, 1);
    });

    test('the file stays bounded', () async {
      final store = storeIn(dir);
      var h = ResetHistory.empty;
      for (var i = 0; i < HistoryStore.maxRecords + 25; i++) {
        h = await store.append(h, _rec(daysAgo(1)));
      }
      expect(h.totalCount, HistoryStore.maxRecords);
      expect((await store.load()).totalCount, HistoryStore.maxRecords);
    });
  });
}
