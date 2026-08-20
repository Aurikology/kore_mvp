import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/focus_crash_predictor.dart';
import 'package:kore/theme/kore_theme.dart';
import 'package:kore/widgets/forecast_notice.dart';

/// The predictor earns its five statuses by refusing to collapse them. These
/// pin that refusal at the surface: four of the five say nothing, and the one
/// that speaks says how sure it is by how coarsely it counts.
void main() {
  CrashForecast forecast(
    CrashForecastStatus status, {
    double? seconds,
    double confidence = 0.8,
  }) =>
      CrashForecast(
        status: status,
        secondsToCrossing: seconds,
        confidence: confidence,
        indexSlopePerSecond: 1.2,
        ratioSlopePerSecond: 0.03,
        fit: 0.9,
      );

  Future<void> pumpNotice(WidgetTester tester, CrashForecast f) =>
      tester.pumpWidget(MaterialApp(
        theme: KoreTheme.dark(),
        home: Scaffold(body: ForecastNotice(forecast: f)),
      ));

  group('ForecastNotice', () {
    for (final status in [
      CrashForecastStatus.uncalibrated,
      CrashForecastStatus.warmingUp,
      CrashForecastStatus.steady,
      CrashForecastStatus.alreadyStrained,
    ]) {
      testWidgets('says nothing when ${status.name}', (tester) async {
        await pumpNotice(tester, forecast(status, seconds: 12));

        // Including `steady`, which has a forecast and deliberately withholds
        // it: "no crossing inside the horizon" is not a promise of calm.
        expect(find.byType(Text), findsNothing);
      });
    }

    testWidgets('speaks only when a crash is likely', (tester) async {
      await pumpNotice(
          tester, forecast(CrashForecastStatus.crashLikely, seconds: 14));

      expect(find.text('Trending toward strain — about 15 seconds out'),
          findsOneWidget);
    });

    testWidgets('carries no tint of its own', (tester) async {
      await pumpNotice(
          tester, forecast(CrashForecastStatus.crashLikely, seconds: 14));

      // A prediction is a weaker claim than a reading, so it must not borrow
      // the strain colour - and KORE has no alarm colour to borrow anyway.
      final style = tester.widget<Text>(find.byType(Text)).style!;
      expect(style.color, KoreColors.dark.textSecondary);
    });
  });

  group('phrase', () {
    test('rounds to five seconds', () {
      // The fit is a line through noisy data. Printing 13.4 would dress a
      // trend line up as a countdown.
      expect(ForecastNotice.phrase(13.4), contains('about 15 seconds'));
      expect(ForecastNotice.phrase(17.6), contains('about 20 seconds'));
    });

    test('collapses anything imminent rather than counting down to zero', () {
      expect(ForecastNotice.phrase(2.0), 'Trending toward strain — moments away');
      expect(ForecastNotice.phrase(0.0), 'Trending toward strain — moments away');
    });

    test('still says something when there is no crossing time', () {
      expect(ForecastNotice.phrase(null), 'Trending toward strain');
    });
  });
}
