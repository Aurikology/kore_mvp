import 'package:flutter/material.dart';

import '../session/kore_history.dart';
import '../theme/kore_theme.dart';
import '../widgets/load_trend.dart';
import '../widgets/load_trend_card.dart';

/// The longitudinal detail, reached from the trend card on the dashboard.
///
/// A route rather than a tab, for the reason `docs/design/mobile.md` gives for
/// history: two destinations do not justify a bottom navigation bar, and a tap
/// on the thing you are already reading is a cheaper decision than a
/// permanent second choice at the bottom of every screen.
///
/// Everything here is a snapshot taken at push time. The daily log only
/// changes when the session writes, which cannot happen while this route is on
/// top of the dashboard, so listening to the session would buy a rebuild that
/// never fires.
class TrendScreen extends StatelessWidget {
  final DailyLoadLog log;
  final DateTime today;

  /// Live from the session. The chart's reference rule and the sentence's
  /// "your threshold of 78" both come from here rather than from
  /// `CognitiveLoadIndex.kStrainEnter`, which stops being this user's number
  /// the moment the profile personalises it.
  final double strainEnter;
  final bool thresholdsPersonalised;

  static const int span = KoreTrend.screenSpan;

  const TrendScreen({
    super.key,
    required this.log,
    required this.today,
    required this.strainEnter,
    required this.thresholdsPersonalised,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Load over time')),
      body: SafeArea(
        // Classified off the constraints rather than the window, exactly as
        // the dashboard is, so this route is correct inside any box it is
        // given.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final layout = KoreBreakpoints.classify(constraints.biggest);
            final window = TrendWindow.of(log, today: today, span: span);

            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: KoreBreakpoints.gutter(layout),
                    vertical: KoreSpace.md,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LoadTrendCard(
                        log: log,
                        today: today,
                        strainEnter: strainEnter,
                        thresholdsPersonalised: thresholdsPersonalised,
                        layout: layout,
                        span: span,
                      ),
                      const SizedBox(height: KoreSpace.md),
                      _measured(context, window),
                      const SizedBox(height: KoreSpace.lg),
                      _footnote(context),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _measured(BuildContext context, TrendWindow window) {
    final k = context.kore;
    final text = Theme.of(context).textTheme;
    final mean = log.meanIndexOverLastDays(today, span);
    final peak = window.peakIndex;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(KoreSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('WHAT WAS MEASURED',
                style: text.labelMedium
                    ?.copyWith(letterSpacing: KoreType.trackedLabel)),
            const SizedBox(height: KoreSpace.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // A count is not a reading, so it takes the type colour rather
                // than a place on the load ramp.
                _stat(context, '${window.measuredDays}', 'days measured',
                    k.textPrimary),
                _stat(
                  context,
                  mean == null ? '--' : mean.round().toString(),
                  'mean load',
                  mean == null ? k.unmeasured : k.forLoad(mean),
                ),
                _stat(
                  context,
                  peak == null ? '--' : peak.round().toString(),
                  'highest reading',
                  peak == null ? k.unmeasured : k.forLoad(peak),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The rule the chart is applying, in words, on the surface that has room
  /// for it. Without this the muted bars are a mystery rather than an
  /// explanation of why a trend is being withheld.
  Widget _footnote(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'A day counts toward the trend once KORE has measured a full minute '
          'of load on it. Shorter days are drawn faint and left out of the '
          'line: their average is whatever you happened to be doing while the '
          'app was open.',
          style: text.bodySmall,
        ),
        const SizedBox(height: KoreSpace.xs),
        Text(
          'Today joins the chart the next time KORE writes to disk, which it '
          'does when a reset is logged.',
          style: text.bodySmall,
        ),
      ],
    );
  }

  Widget _stat(
      BuildContext context, String value, String label, Color color) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: KoreType.numerals(
                  fontSize: KoreType.size28, color: color)),
          const SizedBox(height: 2),
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: context.kore.textSecondary)),
        ],
      ),
    );
  }
}
