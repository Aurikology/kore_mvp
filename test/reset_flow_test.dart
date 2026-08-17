import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/main.dart';
import 'package:kore/widgets/reset_protocol_sheet.dart';

void main() {
  testWidgets('running a reset opens the guided protocol and can be ended',
      (tester) async {
    await tester.pumpWidget(const KoreApp());
    await tester.pump(const Duration(milliseconds: 100));

    // The CTA is always live - gating it behind a strain threshold would mean
    // waiting on the simulation before you could show the loop.
    await tester.tap(find.text('Run a reset'));
    // Fixed pumps rather than pumpAndSettle: the breathing animation repeats
    // forever, so settling would never complete.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(ResetProtocolSheet), findsOneWidget);
    expect(find.text('RESET PROTOCOL'), findsOneWidget);
    expect(find.text('0:60'), findsOneWidget);

    // Box breathing starts on the inhale.
    expect(find.text('Breathe in'), findsOneWidget);

    await tester.tap(find.text('End early'));
    await tester.pump();
    // Cover the full route-pop transition. pumpAndSettle is unavailable here:
    // the breathing animation repeats forever, so it would never settle.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(find.byType(ResetProtocolSheet), findsNothing);

    // Back on the dashboard.
    expect(find.text('Run a reset'), findsOneWidget);
  });

  testWidgets('demo controls are present and reachable', (tester) async {
    // These are the presenter's safety net - if they ever stop rendering,
    // a live demo is at the mercy of a wall clock.
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const KoreApp());
    await tester.pump(const Duration(milliseconds: 100));

    for (final label in ['Simulate strain', 'Simulate calm', 'Recalibrate']) {
      expect(find.text(label), findsOneWidget, reason: 'missing $label');
    }
  });
}
