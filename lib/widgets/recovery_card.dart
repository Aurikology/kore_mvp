import 'package:flutter/material.dart';

import '../session/reset_record.dart';
import '../theme/kore_theme.dart';

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

  const RecoveryCard({super.key, required this.history, required this.today});

  @override
  Widget build(BuildContext context) {
    if (history.completedCount == 0) return const SizedBox.shrink();

    final text = Theme.of(context).textTheme;
    final streak = history.currentStreakDays(today);
    final drop = history.averageDrop;
    final clarity = history.averageClarity;

    return Card(
      child: Padding(
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
                    '${history.completedInLastDays(today, 7)} in the last 7 days',
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
                _stat(context, streak > 0 ? '$streak' : '--', 'day streak'),
                _stat(context, drop == null ? '--' : drop.round().toString(),
                    'avg drop'),
                _stat(context,
                    clarity == null ? '--' : clarity.toStringAsFixed(1),
                    'avg clarity'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(BuildContext context, String value, String label) {
    final k = context.kore;
    // A dash is the absence of a measurement, not a good one. Giving it the
    // calm colour would let an empty statistic read as a win.
    final measured = value != '--';

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: KoreType.numerals(
              fontSize: KoreType.size28,
              color: measured ? k.calm : k.unmeasured,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: k.textSecondary),
          ),
        ],
      ),
    );
  }
}
