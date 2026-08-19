import 'package:flutter/material.dart';

import '../theme/kore_theme.dart';

/// Step 3 of the core loop in `docs/positioning.md`: confirm the uplift.
///
/// Pops with 1-5, or with null when the user skips. Skipping is a first-class
/// answer and is deliberately as easy to reach as the scale - a check-in that
/// is hard to dismiss stops being a measurement and starts being a toll.
class CheckInSheet extends StatelessWidget {
  /// Index points the reading fell over the protocol. Shown alongside the
  /// question so the self-report and the measurement sit together.
  final double drop;

  const CheckInSheet({super.key, required this.drop});

  static const List<String> _labels = [
    'Foggy',
    'Murky',
    'Neutral',
    'Clear',
    'Sharp',
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final k = context.kore;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            KoreSpace.lg, KoreSpace.xl, KoreSpace.lg, KoreSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('RESET COMPLETE',
                textAlign: TextAlign.center,
                style: text.labelMedium
                    ?.copyWith(letterSpacing: KoreType.trackedEyebrow)),
            const SizedBox(height: KoreSpace.sm),
            Text(
              'How clear do you feel?',
              textAlign: TextAlign.center,
              style: text.headlineSmall,
            ),
            const SizedBox(height: KoreSpace.xs),
            // Always secondary, never coloured by the result. A reset that
            // moved the index the wrong way is information, not a failure to
            // flag at someone who has just spent a minute breathing.
            Text(
              _measured(),
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: k.textSecondary),
            ),
            const SizedBox(height: KoreSpace.xl),
            LayoutBuilder(
              builder: (context, constraints) {
                final d = KoreCheckIn.optionDiameter(constraints.maxWidth);
                return Row(
                  children: [
                    for (var i = 1; i <= 5; i++) _option(context, i, d),
                  ],
                );
              },
            ),
            const SizedBox(height: KoreSpace.md),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Skip'),
            ),
          ],
        ),
      ),
    );
  }

  /// States the measurement plainly, including when it went the wrong way.
  /// A reset that did not move the index should say so.
  String _measured() {
    if (drop >= 1) return 'Your load fell ${drop.round()} points';
    if (drop <= -1) return 'Your load rose ${(-drop).round()} points';
    return 'Your load held steady';
  }

  Widget _option(BuildContext context, int value, double diameter) {
    final k = context.kore;

    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: diameter,
            height: diameter,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.square(diameter),
                shape: const CircleBorder(),
              ),
              onPressed: () => Navigator.of(context).pop(value),
              child: Text(
                '$value',
                style: KoreType.numerals(
                    fontSize: KoreType.size18, color: k.accent),
              ),
            ),
          ),
          const SizedBox(height: KoreSpace.xxs),
          Text(
            _labels[value - 1],
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
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
