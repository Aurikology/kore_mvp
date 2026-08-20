import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/app/home_page.dart';
import 'package:kore/session/kore_session.dart';
import 'package:kore/sources/simulated_eeg_source.dart';
import 'package:kore/theme/kore_theme.dart';

/// The seam test. The engine decides whether a reading can be believed; the
/// dashboard decides what to draw. Each half was correct on its own the last
/// time they disagreed, and the bug lived in the gap - so this drives the
/// whole app rather than any one widget.
void main() {
  /// Boots the real dashboard against a session whose clock is the test's.
  /// Without the injected clock the simulated source reads a real `Stopwatch`,
  /// no samples are produced under fake time, and the screen sits on
  /// CALIBRATING forever - so none of the states below would ever be reached.
  Future<KoreSession> boot(WidgetTester tester) async {
    // Tall enough that the demo controls are on screen without scrolling.
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final start = tester.binding.clock.now();
    final session = KoreSession(
      source: SimulatedEegSource(
        autoTimeline: false,
        elapsedMicros: () =>
            tester.binding.clock.now().difference(start).inMicroseconds,
      ),
    );

    await tester.pumpWidget(MaterialApp(
      theme: KoreTheme.dark(),
      home: HomePage(session: session),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    return session;
  }

  testWidgets('a detached electrode is reported, not absorbed',
      (tester) async {
    final session = await boot(tester);

    // Nothing wrong yet, so nothing said.
    expect(find.text('The electrode is not making contact'), findsNothing);

    await tester.tap(find.text('Detach electrode'));
    await tester.pump(const Duration(seconds: 3));

    expect(find.text('The electrode is not making contact'), findsOneWidget);
    session.dispose();
  });

  testWidgets('never claims the user is steady while it cannot see them',
      (tester) async {
    final session = await boot(tester);

    // Calibrate on a good signal first. Detaching before the baseline lands
    // stalls calibration instead, which is correct but is a different case -
    // the hazard here is an electrode that comes off *after* the app has a
    // reading it believes.
    await tester.pump(const Duration(seconds: 30));
    await tester.tap(find.text('Detach electrode'));
    await tester.pump(const Duration(seconds: 5));

    // The gate withdraws strain, which leaves `steady` behind. If the chip
    // renders the state without consulting quality, this is where it says
    // "Steady" about a user it has no signal from.
    expect(find.text('Steady'), findsNothing);
    expect(find.text('Not reading you right now'), findsOneWidget);
    session.dispose();
  });

  testWidgets('recovers once contact is restored', (tester) async {
    final session = await boot(tester);

    await tester.pump(const Duration(seconds: 30));
    await tester.tap(find.text('Detach electrode'));
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Not reading you right now'), findsOneWidget);

    await tester.tap(find.text('Restore contact'));
    // Long enough to clear the settling window, which deliberately outlasts
    // the fault itself.
    await tester.pump(const Duration(seconds: 10));

    expect(find.text('The electrode is not making contact'), findsNothing);
    expect(find.text('Not reading you right now'), findsNothing);
    session.dispose();
  });
}
