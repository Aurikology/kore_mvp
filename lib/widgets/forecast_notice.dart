import 'package:flutter/material.dart';

import '../dsp/focus_crash_predictor.dart';
import '../theme/kore_theme.dart';

/// The forecast, when there is one worth showing.
///
/// This is the quietest thing on the dashboard on purpose. A forecast is a
/// weaker claim than a reading - the index says what is, this says what the
/// last twelve seconds imply - so it is rendered *below* the state chip's
/// weight, in secondary text, with no tint and no icon. KORE has no alarm
/// colour by design, and a prediction is the last place to introduce one.
///
/// Four of the five statuses render nothing at all. That is the point of
/// having five: `warmingUp` and `steady` both mean "no warning", but neither
/// means "you are fine", and the honest way to render a claim the predictor
/// has not made is to make none.
class ForecastNotice extends StatelessWidget {
  final CrashForecast forecast;

  const ForecastNotice({super.key, required this.forecast});

  /// Rounded to five seconds. The fit is a straight line through noisy data
  /// with an R^2 that is rarely near 1, so "about 15 seconds" is the honest
  /// resolution; printing 13.4 would dress a trend line up as a countdown.
  static String phrase(double? secondsToCrossing) {
    if (secondsToCrossing == null) return 'Trending toward strain';
    final rounded = (secondsToCrossing / 5).round() * 5;
    if (rounded <= 5) return 'Trending toward strain — moments away';
    return 'Trending toward strain — about $rounded seconds out';
  }

  @override
  Widget build(BuildContext context) {
    // Deliberately not a switch on `isWarning`: the other four statuses are
    // silent for four different reasons, and collapsing them here would lose
    // the distinction the predictor went to the trouble of making.
    if (forecast.status != CrashForecastStatus.crashLikely) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: KoreSpace.xs),
      child: Text(
        phrase(forecast.secondsToCrossing),
        textAlign: TextAlign.center,
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: context.kore.textSecondary),
      ),
    );
  }
}
