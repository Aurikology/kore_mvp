import 'package:flutter/material.dart';

import '../session/reset_record.dart';
import '../theme.dart';

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

    // Owns the gap below it so that rendering nothing leaves no gap at all.
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('RECOVERY',
                      style: text.labelMedium?.copyWith(letterSpacing: 1.4)),
                  const Spacer(),
                  Text(
                    '${history.completedInLastDays(today, 7)} in the last 7 days',
                    style: text.labelSmall,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  _stat(text, streak > 0 ? '$streak' : '--', 'day streak'),
                  _stat(
                    text,
                    drop == null ? '--' : drop.round().toString(),
                    'avg drop',
                  ),
                  _stat(
                    text,
                    clarity == null ? '--' : clarity.toStringAsFixed(1),
                    'avg clarity',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stat(TextTheme text, String value, String label) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: KoreTheme.numerals(fontSize: 28, color: KoreTheme.sage)),
          const SizedBox(height: 2),
          Text(label,
              style: text.labelSmall?.copyWith(color: KoreTheme.textSecondary)),
        ],
      ),
    );
  }
}
