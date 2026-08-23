import 'package:flutter/material.dart';

import '../session/reset_record.dart';
import '../theme/kore_theme.dart';
import 'stat_figure.dart';

/// Step 4 of the core loop: reinforce with streaks and recovery trends.
///
/// Renders nothing until the first reset is logged. An empty card reading
/// "0 day streak, no data" on first launch teaches the user that the feature
/// is dead weight before they have had a chance to use it.
class RecoveryCard extends StatelessWidget {
  final ResetHistory history;

  /// Injected rather than read from the clock so the widget is testable and
  /// so a single render cannot straddle midnight.
  final DateTime today;

  /// Null on the history screen, which is already the destination. The whole
  /// card is the affordance, exactly as `LoadTrendCard` is - two destinations
  /// do not justify a tab bar, and a tap on the summary someone is already
  /// reading is free.
  final VoidCallback? onOpen;

  const RecoveryCard({
    super.key,
    required this.history,
    required this.today,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    if (history.completedCount == 0) return const SizedBox.shrink();

    final text = Theme.of(context).textTheme;
    final streak = history.currentStreakDays(today);
    final drop = history.averageDrop;
    final clarity = history.averageClarity;

    final body = Padding(
        padding: const EdgeInsets.all(KoreSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('RECOVERY',
                    style: text.labelMedium
                        ?.copyWith(letterSpacing: KoreType.trackedLabel)),
                const Spacer(),
                Flexible(
                  child: Text(
                    onOpen == null
                        ? '${history.completedInLastDays(today, 7)} in the last 7 days'
                        // A word rather than a chevron, for the reason the
                        // trend card gives: two bundled fonts, no icon set,
                        // and a word survives every accessibility setting.
                        : 'See every reset',
                    style: text.labelSmall,
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
            const SizedBox(height: KoreSpace.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                StatFigure(
                  value: streak > 0 ? '$streak' : '--',
                  label: 'day streak',
                  measured: streak > 0,
                ),
                StatFigure.orDash(
                    value: drop?.round().toString(), label: 'avg drop'),
                StatFigure.orDash(
                    value: clarity?.toStringAsFixed(1), label: 'avg clarity'),
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
