import 'package:flutter/material.dart';

import '../theme.dart';

/// Placeholder shell. Replaced in Phase 3 by the live dashboard once the
/// DSP pipeline (Phase 2) is in place and tested.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('KORE', style: t.displayMedium),
            const SizedBox(height: 8),
            Text('Cognitive Load Index',
                style: t.bodyMedium?.copyWith(color: KoreTheme.textSecondary)),
          ],
        ),
      ),
    );
  }
}
