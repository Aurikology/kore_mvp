import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/session/kore_session.dart';
import 'package:kore/theme.dart';
import 'package:kore/widgets/reset_protocol_sheet.dart';

/// Regression test for a bug that only showed up in the running app.
///
/// [ResetProtocolSheet] pops itself when the session reports the reset is over.
/// `Navigator.push` completes the moment `pop()` is called, not when the exit
/// animation finishes, so the dashboard pushes the check-in while this route is
/// still mounted and still listening - and the session keeps notifying at 4 Hz.
/// Every one of those notifications used to call `maybePop()` again, which
/// closed the check-in about 250 ms after it opened. Resets were logged with a
/// null rating and the sheet was never visible long enough to notice.
void main() {
  testWidgets('does not pop a route pushed after it leaves', (tester) async {
    // No start(): the sample stream is not needed, and leaving it unstarted
    // keeps the test off the wall clock.
    final session = KoreSession();
    addTearDown(session.dispose);

    final navKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      theme: KoreTheme.darkTheme(),
      home: const Scaffold(body: Center(child: Text('dashboard'))),
    ));

    session.startReset();
    unawaited(navKey.currentState!.push(MaterialPageRoute(
      builder: (_) => ResetProtocolSheet(session: session),
    )));
    // Fixed pumps, never pumpAndSettle: the breathing animation repeats
    // forever, so settling pumps long enough for the 60 s reset timer to fire
    // and pop the sheet before the assertion below ever runs.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('RESET PROTOCOL'), findsOneWidget);

    // The protocol ends. The sheet begins popping.
    session.cancelReset();
    await tester.pump();

    // The dashboard pushes the follow-up immediately, exactly as _openReset
    // does once its push future completes.
    unawaited(navKey.currentState!.push(MaterialPageRoute(
      builder: (_) => const Scaffold(body: Center(child: Text('check-in'))),
    )));
    await tester.pump();

    // Further notifications arrive while the protocol route is still animating
    // out. These are what used to close the check-in.
    for (var i = 0; i < 6; i++) {
      session.simulateCalm();
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Cover the rest of the pop transition.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(find.text('check-in'), findsOneWidget,
        reason: 'the outgoing protocol sheet popped the check-in');
    expect(find.text('RESET PROTOCOL'), findsNothing);
  });
}

/// Local stand-in so the test does not need dart:async imported for one call.
void unawaited(Future<void> f) {}
