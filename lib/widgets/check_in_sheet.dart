import 'package:flutter/material.dart';

import '../theme.dart';

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

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('RESET COMPLETE',
                textAlign: TextAlign.center,
                style: text.labelMedium?.copyWith(letterSpacing: 2.0)),
            const SizedBox(height: 14),
            Text(
              'How clear do you feel?',
              textAlign: TextAlign.center,
              style: text.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              _measured(),
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: KoreTheme.textSecondary),
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (var i = 1; i <= 5; i++) _option(context, i),
              ],
            ),
            const SizedBox(height: 18),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Skip',
                  style: text.bodyMedium
                      ?.copyWith(color: KoreTheme.textSecondary)),
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

  Widget _option(BuildContext context, int value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 52,
          height: 52,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.zero,
              shape: const CircleBorder(),
            ),
            onPressed: () => Navigator.of(context).pop(value),
            child: Text('$value', style: KoreTheme.numerals(fontSize: 18)),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _labels[value - 1],
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: KoreTheme.textSecondary),
        ),
      ],
    );
  }
}
