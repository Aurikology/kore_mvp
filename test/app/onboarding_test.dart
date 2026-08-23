import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/app/pair_screen.dart';
import 'package:kore/main.dart';
import 'package:kore/services/history_store.dart';
import 'package:kore/session/kore_history.dart';
import 'package:kore/session/kore_session.dart';
import 'package:kore/sources/simulated_eeg_source.dart';
import 'package:kore/theme/kore_theme.dart';

/// The first run, and the fact that it only happens once.
void main() {
  /// A temp directory that cleans itself up. Synchronous IO throughout: a
  /// `testWidgets` body runs under a fake clock, and an awaited real file
  /// operation there never completes.
  Directory tempDir(String prefix) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // The session may still hold the file; a stranded temp directory is
        // not worth failing a passing test over.
      }
    });
    return dir;
  }

  /// Pumps the whole app against a store, letting the real read on the way up
  /// complete before the tree is inspected.
  ///
  /// Everything in this group runs in real time, and it has to: the session
  /// reads the history document with real file IO before it starts the source,
  /// and a future created under the binding's fake clock never completes
  /// however long the test pumps for. The pairing screen's scan and connect
  /// delays are real for the same reason.
  Future<void> boot(WidgetTester tester, HistoryStore store) async {
    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await tester.pumpWidget(KoreApp(store: store));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
  }

  /// Taps in real time and waits out whatever the tap set going.
  Future<void> tapAndWait(
      WidgetTester tester, Finder target, Duration wait) async {
    await tester.runAsync(() async {
      await tester.tap(target);
      // Pumped inside the real-time zone, not after it: the tap only sets
      // state, and whatever it opens does its real work - a document read, a
      // scan - from initState. Waiting before that frame exists waits for
      // nothing.
      await tester.pump();
      await Future<void>.delayed(wait);
      await tester.pump();
    });
    await tester.pump();
  }

  group('the first run', () {
    testWidgets('states the claim boundary before any reading appears',
        (tester) async {
      final file = File('${tempDir('kore_first').path}/history.json');
      await boot(tester, HistoryStore(file));

      expect(find.textContaining('not a medical device'), findsOneWidget);
      expect(find.textContaining('does not diagnose anything'), findsOneWidget);
      expect(find.text('Get started'), findsOneWidget);

      // The point of the screen is that it comes first. A reading visible
      // behind it would defeat it entirely.
      expect(find.text('Run a reset'), findsNothing);
    });

    testWidgets('goes looking for a patch, and can be cancelled while it does',
        (tester) async {
      final file = File('${tempDir('kore_pair').path}/history.json');
      await boot(tester, HistoryStore(file));

      await tapAndWait(tester, find.text('Get started'),
          const Duration(milliseconds: 400));

      expect(find.text('Looking for your patch'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Continue'), findsNothing,
          reason: 'nothing has been found to continue with');

      await tapAndWait(
          tester, find.text('Cancel'), const Duration(milliseconds: 150));
      expect(find.text('Look again'), findsOneWidget);
    });

    testWidgets('reaches the contact check once the patch connects',
        (tester) async {
      final file = File('${tempDir('kore_check').path}/history.json');
      await boot(tester, HistoryStore(file));

      await tapAndWait(
          tester, find.text('Get started'), const Duration(seconds: 3));

      expect(find.text('Contact check'), findsOneWidget);
      expect(find.text('Left pad'), findsOneWidget);
      expect(find.text('Right pad'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
    });

    testWidgets('is not shown again once it has been completed',
        (tester) async {
      final file = File('${tempDir('kore_once').path}/history.json');
      final store = HistoryStore(file);

      await boot(tester, store);
      await tapAndWait(
          tester, find.text('Get started'), const Duration(seconds: 3));
      await tapAndWait(
          tester, find.text('Continue'), const Duration(milliseconds: 250));

      expect(find.text('Contact check'), findsNothing);
      expect(find.text('Run a reset'), findsOneWidget,
          reason: 'continuing lands on the dashboard');

      // And the fact survives the app being torn down and built again.
      final written = jsonDecode(file.readAsStringSync()) as Map;
      expect(written['app']['onboardingCompletedAt'], isNotNull);

      await boot(tester, HistoryStore(file));
      expect(find.text('Get started'), findsNothing);
      expect(find.text('Run a reset'), findsOneWidget);
    });

    testWidgets('a document written before the flag reads as a first run',
        (tester) async {
      final file = File('${tempDir('kore_v2').path}/history.json');
      file.writeAsStringSync(jsonEncode({
        'version': 2,
        'resets': const [],
        'days': const [],
      }));

      await boot(tester, HistoryStore(file));

      // Failing toward showing the screen is the safe direction: it costs one
      // avoidable screen, where the other direction skips the claim boundary.
      expect(find.text('Get started'), findsOneWidget);
    });

    testWidgets('is skipped entirely when nothing can be remembered',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const KoreApp());
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Get started'), findsNothing,
          reason: 'a screen shown "once, ever" cannot be honoured by '
              'something with no memory');
      expect(find.text('Run a reset'), findsOneWidget);
    });
  });

  group('the contact check', () {
    /// The pairing screen against a session whose clock is the test's, so the
    /// pads can be driven directly.
    Future<KoreSession> boot(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 2200);
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
        home: PairScreen(session: session, onContinue: () {}),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      return session;
    }

    testWidgets('lets a seated patch through', (tester) async {
      final session = await boot(tester);

      expect(find.text('Contact check'), findsOneWidget);
      expect(find.text('Good'), findsNWidgets(2));

      final button =
          tester.widget<ElevatedButton>(find.byType(ElevatedButton).last);
      expect(button.onPressed, isNotNull);
      session.dispose();
    });

    testWidgets('blocks on a pad that is not reading, and names it',
        (tester) async {
      final session = await boot(tester);

      session.demo!.setContact(1.0);
      (session.source as SimulatedEegSource).detachPad('left');
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('No contact'), findsOneWidget);
      expect(find.textContaining('Left pad is not reading'), findsOneWidget);

      final button =
          tester.widget<ElevatedButton>(find.byType(ElevatedButton).last);
      expect(button.onPressed, isNull,
          reason: 'a plausible wrong number is worse than no number');
      session.dispose();
    });

    testWidgets('says weak rather than broken for a pad on its way out',
        (tester) async {
      final session = await boot(tester);

      (session.source as SimulatedEegSource).setPadContact('right', 0.45);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Weak'), findsOneWidget);
      expect(find.textContaining('Right pad is reading weakly'), findsOneWidget);
      session.dispose();
    });

    testWidgets('an unmeasurable pad reads as unmeasured, never as good',
        (tester) async {
      final session = await boot(tester);

      (session.source as SimulatedEegSource).setPadContact('left', null);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Not measured'), findsOneWidget);
      expect(find.text('Good'), findsOneWidget);

      // An unmeasurable pad is not a fault, so it does not block the flow -
      // it just never claims to be seated.
      final button =
          tester.widget<ElevatedButton>(find.byType(ElevatedButton).last);
      expect(button.onPressed, isNotNull);
      session.dispose();
    });

    testWidgets('names the simulated patch as simulated', (tester) async {
      final session = await boot(tester);
      expect(find.textContaining('Simulated patch'), findsOneWidget);
      session.dispose();
    });

    testWidgets('says so when the battery cannot be read', (tester) async {
      tester.view.physicalSize = const Size(1200, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final start = tester.binding.clock.now();
      final session = KoreSession(
        source: SimulatedEegSource(
          autoTimeline: false,
          batteryPercent: null,
          elapsedMicros: () =>
              tester.binding.clock.now().difference(start).inMicroseconds,
        ),
      );
      await tester.pumpWidget(MaterialApp(
        theme: KoreTheme.dark(),
        home: PairScreen(session: session, onContinue: () {}),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('battery not reported'), findsOneWidget);
      session.dispose();
    });
  });

  test('the app state section survives a document round trip', () {
    const state = AppState(onboardingCompletedAt: null);
    expect(state.hasOnboarded, isFalse);

    final at = DateTime(2026, 8, 22, 14, 30);
    final doc = KoreHistory.empty
        .copyWith(app: AppState(onboardingCompletedAt: at));
    final back = KoreHistory.fromJson(jsonDecode(jsonEncode(doc.toJson())));

    expect(back.app.onboardingCompletedAt, at);
    expect(back.app.hasOnboarded, isTrue);
  });

  test('an unparseable app section reads as not onboarded', () {
    expect(AppState.fromJson('nonsense').hasOnboarded, isFalse);
    expect(AppState.fromJson({'onboardingCompletedAt': 'yesterday'}).hasOnboarded,
        isFalse);
    expect(AppState.fromJson(null).hasOnboarded, isFalse);
  });
}
