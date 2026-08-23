import 'package:flutter/material.dart';

import '../theme/kore_theme.dart';

/// The first thing a new user sees, and the only screen whose job is to make a
/// claim smaller.
///
/// It exists because the boundary it states is the product's credibility.
/// KORE puts a number between 0 and 100 on someone's mental state, and a
/// number like that is read as clinical unless it is told not to be. Saying so
/// *before* the first reading appears is the whole point: afterwards it reads
/// as a disclaimer walking back something the user already believes.
///
/// Three lines and a button. No carousel, no pagination dots, no illustration
/// of a brain, no permissions, no account - asking for anything before the
/// user has seen a reading is asking them to trust an empty box.
///
/// The copy is fixed in `docs/design/mobile.md` and is quoted here verbatim,
/// split at its sentence boundaries. It is not marketing copy and should not
/// be improved.
class WelcomeScreen extends StatelessWidget {
  final VoidCallback onContinue;

  const WelcomeScreen({super.key, required this.onContinue});

  static const List<String> claims = [
    'KORE measures the balance of two EEG rhythms and turns it into one '
        'number from 0 to 100.',
    'It is a wellness tool, not a medical device.',
    'It does not diagnose anything.',
  ];

  @override
  Widget build(BuildContext context) {
    final kore = context.kore;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: kore.canvas,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              KoreSpace.xl, KoreSpace.xxl, KoreSpace.xl, KoreSpace.xl),
          // Scrolls with a minHeight rather than expanding freely: at 320 px
          // with the largest accessibility text scale the three claims are
          // taller than the screen, and a claim boundary that has been clipped
          // off the bottom is worse than no claim boundary at all.
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                // spaceBetween rather than an Expanded: inside a scroll view
                // the column has no bounded height for a flex child to divide,
                // and the minHeight above is what gives the distribution
                // something to work with. Same shape as the reset sheet.
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('KORE',
                        style: text.headlineLarge
                            ?.copyWith(letterSpacing: 1.5)),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: KoreSpace.xxxl),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < claims.length; i++) ...[
                            if (i > 0) ...[
                              const SizedBox(height: KoreSpace.lg),
                              Divider(height: 1, color: kore.border),
                              const SizedBox(height: KoreSpace.lg),
                            ],
                            Text(claims[i], style: text.bodyLarge),
                          ],
                        ],
                      ),
                    ),
                    SizedBox(
                      height: 52,
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: onContinue,
                        child: const Text('Get started'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
