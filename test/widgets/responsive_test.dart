import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/app/trend_screen.dart';
import 'package:kore/main.dart';
import 'package:kore/session/kore_history.dart';
import 'package:kore/session/kore_session.dart';
import 'package:kore/theme/kore_theme.dart';
import 'package:kore/widgets/check_in_sheet.dart';
import 'package:kore/widgets/load_trend_card.dart';
import 'package:kore/widgets/reset_protocol_sheet.dart';

/// KORE only ever ran in a desktop window, so nothing stopped a widget from
/// assuming one. These pin the layouts to the sizes the product is actually
/// headed for.
///
/// An overflow in Flutter throws, and the binding hands it back through
/// `takeException()`. That makes "does this lay out" an assertion rather than
/// a screenshot someone has to look at.
void main() {
  /// Real device classes, plus the two edges. 320x568 is the smallest phone
  /// still in circulation; 844x390 is that phone on its side, which is where
  /// a fixed-height column goes wrong.
  const sizes = <String, Size>{
    'small phone portrait': Size(320, 568),
    'phone portrait': Size(390, 844),
    'phone landscape': Size(844, 390),
    'tablet portrait': Size(768, 1024),
    'small desktop window': Size(700, 620),
    'desktop': Size(1280, 900),
    'wide desktop': Size(1920, 1080),
  };

  Future<void> sized(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  group('dashboard', () {
    sizes.forEach((name, size) {
      testWidgets('lays out at $name', (tester) async {
        await sized(tester, size);
        await tester.pumpWidget(const KoreApp());
        await tester.pump(const Duration(milliseconds: 100));

        expect(tester.takeException(), isNull);

        // Whatever the layout does with them, these are the four things the
        // screen exists to show.
        expect(find.text('KORE'), findsOneWidget);
        expect(find.text('CALIBRATING'), findsOneWidget);
        expect(find.text('Run a reset'), findsOneWidget);
        expect(find.text('Simulated signal'), findsOneWidget);
      });
    });

    testWidgets('the reset stays in the thumb zone on a phone', (tester) async {
      await sized(tester, const Size(390, 844));
      await tester.pumpWidget(const KoreApp());
      await tester.pump(const Duration(milliseconds: 100));

      // Pinned to a bottom bar, not parked at the end of the scroll: on a
      // phone held one-handed this is the only control that matters and the
      // bottom third is the only comfortable place for it.
      final cta = tester.getRect(find.text('Run a reset'));
      expect(cta.center.dy, greaterThan(844 * 0.75),
          reason: 'the CTA drifted out of thumb reach');

      // And it stays put when the content above it scrolls.
      await tester.drag(find.text('LAST 2 MINUTES'), const Offset(0, -200));
      await tester.pump();
      expect(tester.getRect(find.text('Run a reset')), cta);
    });

    testWidgets('a desktop window splits into two columns', (tester) async {
      await sized(tester, const Size(1280, 900));
      await tester.pumpWidget(const KoreApp());
      await tester.pump(const Duration(milliseconds: 100));

      // The trend sits beside the gauge rather than under it, so the whole
      // dashboard is one glance with no scroll.
      final gauge = tester.getRect(find.text('CALIBRATING'));
      final trend = tester.getRect(find.text('LAST 2 MINUTES'));
      expect(trend.left, greaterThan(gauge.right));
    });

    testWidgets('the demo controls survive every layout', (tester) async {
      // The presenter's safety net - if they ever stop rendering, a live demo
      // is at the mercy of a wall clock.
      for (final size in [const Size(360, 640), const Size(1280, 900)]) {
        await sized(tester, size);
        await tester.pumpWidget(const KoreApp());
        await tester.pump(const Duration(milliseconds: 100));

        for (final label in ['Simulate strain', 'Simulate calm', 'Recalibrate']) {
          expect(find.text(label), findsOneWidget,
              reason: 'missing $label at $size');
        }
      }
    });
  });

  group('check-in sheet', () {
    for (final width in [320.0, 390.0, 600.0]) {
      testWidgets('all five options fit at ${width.round()} wide',
          (tester) async {
        await sized(tester, Size(width, 700));
        await tester.pumpWidget(MaterialApp(
          theme: KoreTheme.dark(),
          home: const Scaffold(body: CheckInSheet(drop: 12)),
        ));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        for (var i = 1; i <= 5; i++) {
          expect(find.text('$i'), findsOneWidget);
        }
        expect(find.text('Skip'), findsOneWidget);
      });
    }
  });

  group('trend view', () {
    final today = DateTime(2026, 8, 19);

    /// [days] consecutive days ending today, each carrying enough measured
    /// load to count. Two days is the sparsest state that still renders; sixty
    /// overflows a thirty-day window, which is what puts the bar packing under
    /// pressure at 320 px.
    DailyLoadLog log(int days) => List.generate(days, (i) => i).fold(
          DailyLoadLog.empty,
          (log, i) => log.record(DailyLoad(
            day: DateTime(today.year, today.month, today.day - i),
            frames: 1200,
            meanIndex: 40 + (i % 7) * 4,
            peakIndex: 60 + (i % 7) * 4,
          )),
        );

    for (final days in [2, 60]) {
      sizes.forEach((name, size) {
        testWidgets('the card holds $days days at $name', (tester) async {
          await sized(tester, size);
          await tester.pumpWidget(MaterialApp(
            theme: KoreTheme.dark(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: LoadTrendCard(
                  log: log(days),
                  today: today,
                  strainEnter: 78,
                  thresholdsPersonalised: true,
                  layout: KoreBreakpoints.classify(size),
                  onOpen: () {},
                ),
              ),
            ),
          ));
          await tester.pump();

          expect(tester.takeException(), isNull);
          // Whatever it can or cannot say about the trend, it says something.
          expect(find.textContaining('load', findRichText: true).evaluate(),
              isNotEmpty);
        });
      });
    }

    sizes.forEach((name, size) {
      testWidgets('the screen lays out at $name', (tester) async {
        await sized(tester, size);
        await tester.pumpWidget(MaterialApp(
          theme: KoreTheme.dark(),
          home: TrendScreen(
            log: log(60),
            today: today,
            strainEnter: 78,
            thresholdsPersonalised: true,
          ),
        ));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text('Load over time'), findsOneWidget);
        expect(find.text('days measured'), findsOneWidget);
      });
    });
  });

  group('reset protocol', () {
    for (final entry in {
      'a small phone': const Size(320, 568),
      'a phone on its side': const Size(844, 390),
      'a short desktop window': const Size(1000, 400),
    }.entries) {
      testWidgets('fits ${entry.key}', (tester) async {
        await sized(tester, entry.value);

        // No start(): the sample stream is not needed, and leaving it
        // unstarted keeps the test off the wall clock.
        final session = KoreSession();
        addTearDown(session.dispose);
        session.startReset();

        await tester.pumpWidget(MaterialApp(
          theme: KoreTheme.dark(),
          home: ResetProtocolSheet(session: session),
        ));
        // Fixed pumps, never pumpAndSettle: the breathing animation repeats
        // forever, so settling would never complete.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(tester.takeException(), isNull);
        expect(find.text('RESET PROTOCOL'), findsOneWidget);
        expect(find.text('End early'), findsOneWidget);

        // Stops the protocol's one-second timer. The sheet is the root route
        // here, so its maybePop() is a no-op.
        session.cancelReset();
        await tester.pump();
      });
    }
  });
}
