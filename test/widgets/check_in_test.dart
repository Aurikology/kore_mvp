import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/session/reset_record.dart';
import 'package:kore/theme.dart';
import 'package:kore/widgets/check_in_sheet.dart';
import 'package:kore/widgets/recovery_card.dart';

/// What a closed [CheckInSheet] handed back. Mutable so the test can read it
/// *after* pumping the close animation - reading the future's value inline
/// would capture null every time, whatever the user tapped.
class _Outcome {
  bool closed = false;
  int? rating;
}

/// Opens [CheckInSheet] as a modal and records what it pops with.
///
/// Driven through a real route rather than pumped bare, because the value the
/// sheet returns *is* its contract - the dashboard writes whatever comes back.
Future<_Outcome> _showSheet(WidgetTester tester, {double drop = 20}) async {
  final outcome = _Outcome();

  await tester.pumpWidget(MaterialApp(
    theme: KoreTheme.darkTheme(),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              outcome.rating = await showModalBottomSheet<int>(
                context: context,
                builder: (_) => CheckInSheet(drop: drop),
              );
              outcome.closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.text('How clear do you feel?'), findsOneWidget,
      reason: 'sheet did not open');

  return outcome;
}

void main() {
  group('CheckInSheet', () {
    testWidgets('returns the tapped rating', (tester) async {
      final outcome = await _showSheet(tester);
      await tester.tap(find.text('4'));
      await tester.pumpAndSettle();

      expect(outcome.closed, isTrue);
      expect(outcome.rating, 4);
      expect(find.text('How clear do you feel?'), findsNothing);
    });

    testWidgets('Skip closes with no rating rather than a default',
        (tester) async {
      final outcome = await _showSheet(tester);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      expect(outcome.closed, isTrue);
      expect(outcome.rating, isNull);
    });

    testWidgets('dismissing by tapping outside also yields no rating',
        (tester) async {
      final outcome = await _showSheet(tester);
      // Barrier tap: the same path as a user waving the sheet away.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(outcome.closed, isTrue);
      expect(outcome.rating, isNull);
    });

    testWidgets('offers the full 1-5 scale', (tester) async {
      await _showSheet(tester);
      for (var i = 1; i <= 5; i++) {
        expect(find.text('$i'), findsOneWidget, reason: 'missing option $i');
      }
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
    });

    testWidgets('states the measurement, including when it went up',
        (tester) async {
      await _showSheet(tester, drop: -12);
      // Never dress a worse reading up as an improvement.
      expect(find.text('Your load rose 12 points'), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
    });

    testWidgets('a flat reading says so rather than rounding to a win',
        (tester) async {
      await _showSheet(tester, drop: 0.4);
      expect(find.text('Your load held steady'), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
    });
  });

  group('RecoveryCard', () {
    final today = DateTime(2026, 3, 14);

    Future<void> pumpCard(WidgetTester tester, ResetHistory history) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: KoreTheme.darkTheme(),
        home: Scaffold(
          body: RecoveryCard(history: history, today: today),
        ),
      ));
    }

    testWidgets('renders nothing before the first completed reset',
        (tester) async {
      await pumpCard(tester, ResetHistory.empty);
      expect(find.text('RECOVERY'), findsNothing);
    });

    testWidgets('an abandoned reset alone is still nothing to show',
        (tester) async {
      await pumpCard(
          tester,
          ResetHistory([
            ResetRecord(
              startedAt: DateTime(2026, 3, 14, 9).toUtc(),
              completed: false,
              loadBefore: 80,
              loadAfter: 79,
            ),
          ]));
      expect(find.text('RECOVERY'), findsNothing);
    });

    testWidgets('shows streak, average drop and clarity', (tester) async {
      await pumpCard(
          tester,
          ResetHistory([
            ResetRecord(
              startedAt: DateTime(2026, 3, 13, 9).toUtc(),
              completed: true,
              loadBefore: 80,
              loadAfter: 60,
              clarity: 4,
            ),
            ResetRecord(
              startedAt: DateTime(2026, 3, 14, 9).toUtc(),
              completed: true,
              loadBefore: 70,
              loadAfter: 60,
              clarity: 5,
            ),
          ]));

      expect(find.text('RECOVERY'), findsOneWidget);
      expect(find.text('2'), findsOneWidget); // day streak
      expect(find.text('15'), findsOneWidget); // avg drop
      expect(find.text('4.5'), findsOneWidget); // avg clarity
      expect(find.text('2 in the last 7 days'), findsOneWidget);
    });

    testWidgets('shows a dash rather than a zero when nobody rated',
        (tester) async {
      await pumpCard(
          tester,
          ResetHistory([
            ResetRecord(
              startedAt: DateTime(2026, 3, 14, 9).toUtc(),
              completed: true,
              loadBefore: 70,
              loadAfter: 60,
            ),
          ]));
      expect(find.text('--'), findsOneWidget);
    });
  });
}
