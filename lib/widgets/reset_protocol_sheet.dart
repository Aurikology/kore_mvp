import 'package:flutter/material.dart';

import '../session/kore_session.dart';
import '../theme.dart';

/// The guided reset: a 60 second box-breathing protocol.
///
/// This is the half of the loop that makes KORE a product rather than a
/// monitor. The pulse runs at the 10 Hz-adjacent cadence the positioning docs
/// describe, and on completion the simulated load decays so the index visibly
/// falls on the meter behind it.
class ResetProtocolSheet extends StatefulWidget {
  final KoreSession session;

  const ResetProtocolSheet({super.key, required this.session});

  @override
  State<ResetProtocolSheet> createState() => _ResetProtocolSheetState();
}

class _ResetProtocolSheetState extends State<ResetProtocolSheet>
    with SingleTickerProviderStateMixin {
  /// Box breathing: inhale 4, hold 4, exhale 4, hold 4.
  static const int _phaseSeconds = 4;
  static const int _cycleSeconds = _phaseSeconds * 4;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: _cycleSeconds),
  )..repeat();

  @override
  void initState() {
    super.initState();
    // The session is started by the caller before this route is pushed.
    // Mutating it here would notify listeners during the build phase and
    // mark the dashboard's AnimatedBuilder dirty mid-build.
    widget.session.addListener(_onSession);
  }

  void _onSession() {
    if (!mounted) return;
    if (!widget.session.resetActive) {
      Navigator.of(context).maybePop();
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    _controller.dispose();
    super.dispose();
  }

  /// Maps position within the 16 s cycle to a breath phase and a 0-1 scale.
  (String, double) _phase(double t) {
    final pos = t * _cycleSeconds;
    if (pos < 4) return ('Breathe in', 0.6 + 0.4 * (pos / 4));
    if (pos < 8) return ('Hold', 1.0);
    if (pos < 12) return ('Breathe out', 1.0 - 0.4 * ((pos - 8) / 4));
    return ('Hold', 0.6);
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final t = session.resetSecondsRemaining;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: KoreTheme.bg,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('RESET PROTOCOL',
                  style: text.labelMedium?.copyWith(letterSpacing: 2.0)),
              const SizedBox(height: 40),
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final (label, scale) = _phase(_controller.value);
                  return Column(
                    children: [
                      SizedBox(
                        width: 240,
                        height: 240,
                        child: Center(
                          child: Transform.scale(
                            scale: scale,
                            child: Container(
                              width: 220,
                              height: 220,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: KoreTheme.sage.withValues(alpha: 0.12),
                                border: Border.all(
                                    color: KoreTheme.sage.withValues(alpha: 0.7),
                                    width: 2),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      Text(label, style: text.headlineMedium),
                    ],
                  );
                },
              ),
              const SizedBox(height: 40),
              Text(
                '0:${t.toString().padLeft(2, '0')}',
                style: KoreTheme.numerals(
                    fontSize: 34, color: KoreTheme.textSecondary),
              ),
              const SizedBox(height: 32),
              TextButton(
                onPressed: () => session.cancelReset(),
                child: Text('End early',
                    style: text.bodyMedium
                        ?.copyWith(color: KoreTheme.textSecondary)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
