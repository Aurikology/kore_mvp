import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/app/history_screen.dart';
import 'package:kore/session/reset_record.dart';
import 'package:kore/theme/kore_theme.dart';
import 'package:kore/widgets/recovery_card.dart';

void main() {
  final today = DateTime(2026, 8, 22, 18, 0);

  ResetRecord reset({
    required int daysAgo,
    int hour = 9,
    bool completed = true,
    double before = 72,
    double after = 58,
    int? clarity,
  }) =>
      ResetRecord(
        startedAt: DateTime(today.year, today.month, today.day - daysAgo, hour),
        completed: completed,
        loadBefore: before,
        loadAfter: after,
        clarity: clarity,
      );

  Future<void> pumpHistory(WidgetTester tester, ResetHistory history) async {
    tester.view.physicalSize = const Size(1100, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: KoreTheme.dark(),
      home: HistoryScreen(history: history, today: today),
    ));
    await tester.pump();
  }

  group('grouping', () {
    test('is newest day first, and newest reset first inside a day', () {
      final days = HistoryScreen.groupByDay([
        reset(daysAgo: 2, hour: 9),
        reset(daysAgo: 0, hour: 8),
        reset(daysAgo: 0, hour: 14),
      ]);

      expect(days.length, 2);
      expect(days.first.day.day, today.day);
      expect(days.first.records.first.startedAt.hour, 14,
          reason: 'a list someone scrolls wants the newest at the top; the '
              'stored order is left alone');
      expect(days.last.records.single.startedAt.hour, 9);
    });

    test('names only the two days a user can place without arithmetic', () {
      expect(HistoryScreen.labelForDay(DateTime(2026, 8, 22), today), 'TODAY');
      expect(
          HistoryScreen.labelForDay(DateTime(2026, 8, 21), today), 'YESTERDAY');
      expect(HistoryScreen.labelForDay(DateTime(2026, 8, 19), today), '19 AUG');
    });

    test('crosses a month boundary without inventing a day', () {
      final newYear = DateTime(2026, 1, 1, 12);
      expect(HistoryScreen.labelForDay(DateTime(2025, 12, 31), newYear),
          'YESTERDAY');
    });
  });

  testWidgets('an empty history says so in one line, with no apology',
      (tester) async {
    await pumpHistory(tester, ResetHistory.empty);

    expect(find.textContaining('once you have finished one'), findsOneWidget);
    expect(find.text('TODAY'), findsNothing);
  });

  testWidgets('a completed reset shows what it moved', (tester) async {
    await pumpHistory(
        tester, ResetHistory([reset(daysAgo: 0, before: 74, after: 60)]));

    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('-14'), findsOneWidget);
    expect(find.text('DROP'), findsOneWidget);
  });

  testWidgets('a reset that went the wrong way says so', (tester) async {
    await pumpHistory(
        tester, ResetHistory([reset(daysAgo: 0, before: 55, after: 67)]));

    expect(find.text('+12'), findsOneWidget);
    expect(find.text('RISE'), findsOneWidget,
        reason: 'a reset that did not work should say so');
  });

  testWidgets('abandoned resets are present, greyed and labelled',
      (tester) async {
    await pumpHistory(
      tester,
      ResetHistory([
        reset(daysAgo: 0, hour: 8),
        reset(daysAgo: 0, hour: 12, completed: false, after: 71),
      ]),
    );

    // Hiding them would flatter the record, which is the same reason the
    // averages refuse to count them.
    expect(find.text('ABANDONED'), findsOneWidget);
    expect(find.text('no measurement'), findsOneWidget);
    expect(find.text('DROP'), findsOneWidget, reason: 'only the completed one');
  });

  testWidgets('clarity is shown as dots only where it was answered',
      (tester) async {
    await pumpHistory(
      tester,
      ResetHistory([
        reset(daysAgo: 0, hour: 8, clarity: 4),
        reset(daysAgo: 1, hour: 8),
      ]),
    );

    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('YESTERDAY'), findsOneWidget);
    // Five dots for the rated one, none for the skipped one.
    expect(find.byType(Container), findsWidgets);
  });

  testWidgets('the summary refuses to colour a statistic it does not have',
      (tester) async {
    await pumpHistory(
      tester,
      ResetHistory([reset(daysAgo: 0, clarity: null)]),
    );

    // Streak and drop are real; clarity was never answered.
    expect(find.text('--'), findsOneWidget);
    expect(find.text('avg clarity'), findsOneWidget);
  });

  testWidgets('the recovery card is the way in', (tester) async {
    var opened = false;

    tester.view.physicalSize = const Size(1100, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: KoreTheme.dark(),
      home: Scaffold(
        body: RecoveryCard(
          history: ResetHistory([reset(daysAgo: 0)]),
          today: today,
          onOpen: () => opened = true,
        ),
      ),
    ));

    expect(find.text('See every reset'), findsOneWidget);
    await tester.tap(find.byType(RecoveryCard));
    expect(opened, isTrue);
  });

  testWidgets('the card without a destination still reports the week',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: KoreTheme.dark(),
      home: Scaffold(
        body: RecoveryCard(
          history: ResetHistory([reset(daysAgo: 0)]),
          today: today,
        ),
      ),
    ));

    expect(find.text('1 in the last 7 days'), findsOneWidget);
  });
}
