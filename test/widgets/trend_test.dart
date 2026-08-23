import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/main.dart';
import 'package:kore/services/history_store.dart';
import 'package:kore/session/kore_history.dart';
import 'package:kore/theme/kore_theme.dart';
import 'package:kore/widgets/load_trend.dart';
import 'package:kore/widgets/load_trend_card.dart';
import 'package:kore/widgets/load_trend_chart.dart';

/// The trend view's whole job is to be honest about a longitudinal claim, and
/// most of that honesty is a refusal. These pin the refusals: what it says
/// when it cannot fit a line, that the reason it gives is the reason the log
/// actually has, and that a rising reading is drawn exactly as a falling one.
void main() {
  final today = DateTime(2026, 8, 19);

  /// A day carrying five minutes of measured load, which clears the log's
  /// one-minute floor comfortably.
  DailyLoad day(int daysAgo, double mean, {int frames = 1200, double? peak}) =>
      DailyLoad(
        day: DateTime(today.year, today.month, today.day - daysAgo),
        frames: frames,
        meanIndex: mean,
        peakIndex: peak ?? mean + 12,
      );

  DailyLoadLog logOf(List<DailyLoad> days) =>
      days.fold(DailyLoadLog.empty, (log, d) => log.record(d));

  TrendStatement statementFor(
    DailyLoadLog log, {
    int span = KoreTrend.cardSpan,
    double strainEnter = 70,
    bool personalised = false,
  }) =>
      TrendStatement.of(
        log,
        window: TrendWindow.of(log, today: today, span: span),
        strainEnter: strainEnter,
        thresholdsPersonalised: personalised,
      );

  Future<void> pumpCard(
    WidgetTester tester,
    DailyLoadLog log, {
    double strainEnter = 70,
    bool personalised = false,
    VoidCallback? onOpen,
  }) =>
      tester.pumpWidget(MaterialApp(
        theme: KoreTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: LoadTrendCard(
              log: log,
              today: today,
              strainEnter: strainEnter,
              thresholdsPersonalised: personalised,
              layout: KoreWindow.compact,
              onOpen: onOpen,
            ),
          ),
        ),
      ));

  group('TrendWindow', () {
    test('puts every day in its own slot and leaves the gaps empty', () {
      final window = TrendWindow.of(
        logOf([day(9, 40), day(3, 60), day(0, 55)]),
        today: today,
        span: KoreTrend.cardSpan,
      );

      expect(window.slots, hasLength(14));
      expect(window.measuredDays, 3);
      // Oldest first, today last. A day KORE did not measure is null rather
      // than a zero, because a zero is a reading and this is an absence.
      expect(window.slots.last?.meanIndex, 55);
      expect(window.slots[13 - 3]?.meanIndex, 60);
      expect(window.slots[13 - 9]?.meanIndex, 40);
      expect(window.slots[13 - 5], isNull);
    });

    test('drops days that fell out of the window', () {
      final window = TrendWindow.of(
        logOf([day(30, 40), day(1, 60)]),
        today: today,
        span: KoreTrend.cardSpan,
      );

      expect(window.measuredDays, 1);
    });

    test('the peak counts short days, because a peak is an observation', () {
      // A ten-second session's highest reading is as real as an afternoon's;
      // it is only the *mean* that too little time distorts.
      final window = TrendWindow.of(
        logOf([day(2, 50, peak: 62), day(1, 40, frames: 60, peak: 88)]),
        today: today,
        span: KoreTrend.cardSpan,
      );

      expect(window.qualifyingDays, 1);
      expect(window.peakIndex, 88);
    });
  });

  group('TrendStatement', () {
    test('will not draw a line through two days, and says so', () {
      final log = logOf([day(4, 50), day(2, 58)]);
      final statement = statementFor(log);

      expect(statement.hasTrend, isFalse);
      expect(statement.headline, 'Not enough measured days to call a trend.');
      expect(statement.detail, contains('Two days so far have'));
      expect(statement.detail, contains('needs 3'));
    });

    test('the count it names is the count the log will actually fit', () {
      // The window boundary is re-derived in the widget layer because the log
      // does not publish it. This is the guard against the two drifting: the
      // moment the UI claims three qualifying days, `trendPerDay` must agree.
      for (final days in [
        [day(4, 50)],
        [day(4, 50), day(2, 58)],
        [day(4, 50), day(2, 58), day(0, 61)],
      ]) {
        final log = logOf(days);
        final window = TrendWindow.of(log, today: today, span: 14);
        final fitted = log.trendPerDay(today, window: 14) != null;

        expect(window.qualifyingDays >= TrendStatement.minQualifyingDays,
            fitted,
            reason: 'UI counted ${window.qualifyingDays} qualifying days, '
                'log ${fitted ? 'fitted' : 'refused'}');
      }
    });

    test('a day too short to count is not counted', () {
      // Three measured days, but one of them is fifteen seconds of the app
      // being open. The log excludes it and so must the sentence.
      final log = logOf([day(4, 50), day(2, 58), day(0, 61, frames: 60)]);
      final statement = statementFor(log);

      expect(statement.hasTrend, isFalse);
      expect(statement.detail, contains('Two days so far have'));
      expect(log.trendPerDay(today, window: 14), isNull);
    });

    test('says nothing was measured rather than that data is missing', () {
      final statement = statementFor(logOf([day(40, 50), day(35, 55)]));

      expect(statement.headline, 'Nothing measured in the last 14 days.');
    });

    test('states a rising load plainly', () {
      final statement =
          statementFor(logOf([day(12, 50), day(6, 54), day(0, 58)]));

      expect(statement.hasTrend, isTrue);
      expect(statement.headline, 'Your load is rising — about 5 points a week.');
    });

    test('states a falling load in the same shape', () {
      final statement =
          statementFor(logOf([day(12, 58), day(6, 54), day(0, 50)]));

      // "easing", not "improving": the sentence describes the number, and the
      // two directions get the same grammar so neither reads as a verdict.
      expect(statement.headline, 'Your load is easing — about 5 points a week.');
    });

    test('refuses to name a direction inside the noise', () {
      // Two thirds of a point a week, fitted through three daily means. The
      // same call ForecastNotice makes rounding to five seconds: below a point
      // the slope is describing when the user happened to open the app.
      final statement =
          statementFor(logOf([day(13, 55), day(7, 55.6), day(0, 56.2)]));

      expect(statement.headline,
          'Your load is holding steady over the last 14 days.');
    });

    test('quotes the live threshold, and says whose it is', () {
      final log = logOf([day(12, 50), day(6, 54), day(0, 58)]);

      expect(statementFor(log, strainEnter: 78, personalised: true).detail,
          contains('your threshold of 78'));
      // Calling the default "yours" would claim the app had learned something
      // about the user in its first minute.
      expect(statementFor(log, strainEnter: 70).detail,
          contains('the strain threshold of 70'));
    });
  });

  group('LoadTrendCard', () {
    testWidgets('renders nothing before the first measured day', (tester) async {
      await pumpCard(tester, DailyLoadLog.empty);

      // Same rule as RecoveryCard: an empty card on first launch teaches the
      // user the feature is dead weight before they have used it.
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('explains itself rather than showing an empty frame',
        (tester) async {
      await pumpCard(tester, logOf([day(2, 50), day(1, 58)]));

      expect(find.byType(Card), findsOneWidget);
      expect(find.text('Not enough measured days to call a trend.'),
          findsOneWidget);
      expect(find.textContaining('needs 3'), findsOneWidget);
    });

    testWidgets('draws a rising reading exactly as a falling one',
        (tester) async {
      TextStyle headlineStyle(String text) =>
          tester.widget<Text>(find.text(text)).style!;

      await pumpCard(tester, logOf([day(12, 50), day(6, 54), day(0, 58)]));
      final rising = headlineStyle('Your load is rising — about 5 points a week.');

      await pumpCard(tester, logOf([day(12, 58), day(6, 54), day(0, 50)]));
      final easing = headlineStyle('Your load is easing — about 5 points a week.');

      // KORE has no alarm colour and this is the place someone would reach for
      // one. Both directions are primary text, same size, same weight.
      expect(rising.color, KoreColors.dark.textPrimary);
      expect(rising.color, easing.color);
      expect(rising.fontSize, easing.fontSize);
      expect(rising.fontWeight, easing.fontWeight);
      expect(rising.color, isNot(KoreColors.dark.strain));
    });

    testWidgets('prints the personal threshold rather than the constant',
        (tester) async {
      // The bug this whole surface was warned about: a chart ruled at the
      // published 70 while the user's own threshold had moved to 78.
      await pumpCard(
        tester,
        logOf([day(12, 50), day(6, 54), day(0, 58)]),
        strainEnter: 78,
        personalised: true,
      );

      expect(find.textContaining('your threshold of 78'), findsOneWidget);
    });

    testWidgets('a day KORE did not measure is a gap, not a zero',
        (tester) async {
      // The bars are the only channel that shows *when* the load was measured,
      // and they are painted - so nothing else in this file can tell whether
      // they were drawn at all. This reads the pixels.
      const width = 280.0;
      const height = 100.0;
      const slot = width / KoreTrend.cardSpan;

      await tester.pumpWidget(MaterialApp(
        theme: KoreTheme.dark(),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: const ValueKey('chart'),
              child: SizedBox(
                width: width,
                height: height,
                child: LoadTrendChart(
                  // Peak equal to the mean, so no cap overlaps the probe.
                  window: TrendWindow.of(logOf([day(0, 80, peak: 80)]),
                      today: today, span: KoreTrend.cardSpan),
                  strainEnter: 70,
                  height: height,
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();

      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('chart')));
      late final ByteData pixels;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        image.dispose();
      });

      int alphaAt(double x, double y) =>
          pixels.getUint8((y.round() * width.round() + x.round()) * 4 + 3);
      ui.Color colorAt(double x, double y) {
        final i = (y.round() * width.round() + x.round()) * 4;
        return ui.Color.fromARGB(
          pixels.getUint8(i + 3),
          pixels.getUint8(i),
          pixels.getUint8(i + 1),
          pixels.getUint8(i + 2),
        );
      }

      // Today is the last slot, and 80 puts its bar four fifths of the way up.
      // Compared per channel with a byte of slack: the ramp lerps in floating
      // point and the raster rounds to 8 bits.
      const todayCentre = (KoreTrend.cardSpan - 1) * slot + slot / 2;
      final painted = colorAt(todayCentre, 60).toARGB32();
      final expected = KoreColors.dark.forLoad(80).toARGB32();
      for (final shift in [24, 16, 8, 0]) {
        expect((painted >> shift) & 0xFF,
            closeTo((expected >> shift) & 0xFF, 1),
            reason: 'the bar is not the ramp colour for a reading of 80');
      }

      // Every other day is untouched canvas - not a bar of height zero, which
      // would read as "measured, and calm".
      expect(alphaAt(5 * slot + slot / 2, 60), 0);
    });

    testWidgets('the whole card is the way into the detail', (tester) async {
      var opened = false;
      await pumpCard(tester, logOf([day(2, 50), day(1, 58)]),
          onOpen: () => opened = true);

      expect(find.text('See 30 days'), findsOneWidget);
      await tester.tap(find.byType(Card));
      expect(opened, isTrue);
    });
  });

  group('on the dashboard', () {
    /// Everything above pumps the card in isolation. This one goes through the
    /// real app with a real document on disk, because the failure the whole
    /// task exists to fix was not a broken widget - it was a widget that
    /// nothing rendered.
    testWidgets('the trend appears once there are days on file, and opens',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // Synchronous IO throughout the setup: a testWidgets body runs under a
      // fake clock, and an awaited real file operation there never completes.
      final dir = Directory.systemTemp.createTempSync('kore_trend');
      addTearDown(() {
        // The session may still hold the file when the tree comes down, and a
        // stranded temp directory is not worth failing a passing test over.
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException {
          // ignored
        }
      });

      final now = DateTime.now();
      String stamp(int daysAgo) {
        final d = DateTime(now.year, now.month, now.day - daysAgo);
        return '${d.year}-${d.month.toString().padLeft(2, '0')}'
            '-${d.day.toString().padLeft(2, '0')}';
      }

      final file = File('${dir.path}/history.json');
      file.writeAsStringSync(jsonEncode({
        'version': KoreHistory.formatVersion,
        'resets': const [],
        // A user with a fortnight of history has been through the first-run
        // flow by definition. Without this the app opens on the welcome
        // screen, which is correct behaviour and not what this test is about.
        'app': {
          'onboardingCompletedAt':
              now.subtract(const Duration(days: 20)).toIso8601String(),
        },
        'days': [
          for (final (ago, mean) in [(8, 50.0), (4, 54.0), (0, 58.0)])
            {
              'day': stamp(ago),
              'frames': 1200,
              'meanIndex': mean,
              'peakIndex': mean + 12,
            },
        ],
      }));

      // Mounted inside runAsync because the session reads the document with
      // real file IO on the way up, and a future created under the binding's
      // fake clock never completes however long the test pumps for.
      await tester.runAsync(() async {
        await tester.pumpWidget(KoreApp(store: HistoryStore(file)));
        // Two reads, so two waits. The launch gate reads the document to find
        // out whether this is a first run, and the dashboard it then mounts
        // reads it again for the history - and the second read only starts
        // once the first has resolved a frame.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();

      expect(find.text('LAST 14 DAYS'), findsOneWidget);
      expect(find.textContaining('Your load is rising'), findsOneWidget);

      await tester.ensureVisible(find.text('See 30 days'));
      await tester.pump();
      await tester.tap(find.text('See 30 days'));
      // Fixed pumps rather than pumpAndSettle: the sample source runs a
      // periodic timer, so nothing on this route ever settles.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Load over time'), findsOneWidget);
      expect(find.text('LAST 30 DAYS'), findsOneWidget);
    });
  });
}
