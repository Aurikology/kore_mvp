import 'package:flutter/material.dart';

import '../session/kore_history.dart';
import '../theme/kore_theme.dart';
import 'load_trend.dart';
import 'load_trend_chart.dart';

/// The longitudinal view: a fortnight of daily load, stated and drawn.
///
/// The same component serves the dashboard card and the body of the full
/// screen; only [span] and [onOpen] differ. Two spans of one component rather
/// than two components, so the sentence a user reads on the dashboard is
/// written by the same code as the one on the screen behind it.
///
/// **Renders nothing when the log is empty**, exactly as `RecoveryCard` does.
/// The distinction that matters is between *nothing has happened yet* and
/// *something happened and it is not enough*: on a first launch there is no
/// history to explain, and a card reading "not enough data" before the user
/// has finished calibrating teaches them the feature is dead weight. From the
/// first measured day onward the card is always present and always says what
/// it is waiting for - what it must never do is show an empty frame.
class LoadTrendCard extends StatelessWidget {
  final DailyLoadLog log;

  /// Injected rather than read from the clock, for the same reason
  /// `RecoveryCard` takes it: a single render must not straddle midnight, and
  /// every figure on this card has to be directly testable.
  final DateTime today;

  /// Live from the session, never the published constant.
  final double strainEnter;
  final bool thresholdsPersonalised;

  final KoreWindow layout;
  final int span;

  /// Null on the full screen, which is already the destination.
  final VoidCallback? onOpen;

  const LoadTrendCard({
    super.key,
    required this.log,
    required this.today,
    required this.strainEnter,
    required this.thresholdsPersonalised,
    required this.layout,
    this.span = KoreTrend.cardSpan,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    if (log.isEmpty) return const SizedBox.shrink();

    final text = Theme.of(context).textTheme;
    final window = TrendWindow.of(log, today: today, span: span);
    final statement = TrendStatement.of(
      log,
      window: window,
      strainEnter: strainEnter,
      thresholdsPersonalised: thresholdsPersonalised,
    );

    final body = Padding(
      padding: const EdgeInsets.fromLTRB(
          KoreSpace.lg, KoreSpace.md, KoreSpace.lg, KoreSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('LAST $span DAYS',
                  style: text.labelMedium
                      ?.copyWith(letterSpacing: KoreType.trackedLabel)),
              const Spacer(),
              if (onOpen != null)
                // The affordance is a word rather than a chevron: the app
                // ships two bundled fonts and no icon set, and a word is the
                // one channel that survives every accessibility setting.
                Flexible(
                  child: Text('See ${KoreTrend.screenSpan} days',
                      style: text.labelLarge, textAlign: TextAlign.end),
                ),
            ],
          ),
          const SizedBox(height: KoreSpace.md),
          // The trend in words, above the drawing of it. Deliberately in
          // primary text with no tint and no icon: a rising load is rendered
          // exactly as a falling one, because KORE has no alarm colour and
          // colouring the bad reading would turn a measurement into a verdict.
          Text(statement.headline, style: text.titleMedium),
          const SizedBox(height: KoreSpace.xxs),
          Text(statement.detail,
              style: text.bodyMedium?.copyWith(color: context.kore.textSecondary)),
          const SizedBox(height: KoreSpace.md),
          LoadTrendChart(
            window: window,
            strainEnter: strainEnter,
            height: KoreTrend.height(layout),
          ),
          const SizedBox(height: KoreSpace.xs),
          Row(
            children: [
              Text(TrendWindow.shortDate(window.firstDay),
                  style: text.labelSmall),
              const Spacer(),
              Text('Today', style: text.labelSmall),
            ],
          ),
        ],
      ),
    );

    return Card(
      child: onOpen == null
          ? body
          : InkWell(
              onTap: onOpen,
              borderRadius: BorderRadius.circular(KoreRadius.lg),
              child: Semantics(button: true, child: body),
            ),
    );
  }
}
