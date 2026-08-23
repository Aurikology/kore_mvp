import 'package:flutter/material.dart';

import '../theme/kore_theme.dart';

/// One number and its label, with the rule that an absent measurement never
/// borrows the colour of a good one.
///
/// Extracted from `RecoveryCard` when the history screen needed the same three
/// figures at the top of it. The point of sharing it is not the layout - it is
/// that "a dash is the absence of a measurement, not a good one" is a rule
/// worth having in exactly one place, since the failure mode when it drifts is
/// an empty statistic quietly reading as a win.
class StatFigure extends StatelessWidget {
  /// Already formatted, and `--` when there is nothing to show.
  final String value;

  final String label;

  /// Whether [value] is a real measurement. Passed rather than inferred from
  /// the string so a caller with a genuine `--` in its data cannot be
  /// misunderstood.
  final bool measured;

  const StatFigure({
    super.key,
    required this.value,
    required this.label,
    required this.measured,
  });

  /// The common case: `--` means unmeasured.
  factory StatFigure.orDash({
    Key? key,
    required String? value,
    required String label,
  }) =>
      StatFigure(
        key: key,
        value: value ?? '--',
        label: label,
        measured: value != null,
      );

  @override
  Widget build(BuildContext context) {
    final k = context.kore;

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
