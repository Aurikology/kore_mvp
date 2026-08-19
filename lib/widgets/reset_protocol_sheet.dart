import 'package:flutter/material.dart';

import '../session/kore_session.dart';
import '../theme/kore_theme.dart';

/// The guided reset: a 60 second box-breathing protocol.
///
/// This is the half of the loop that makes KORE a product rather than a
/// monitor. On completion the simulated load decays so the index visibly
/// falls on the meter behind it.
///
/// The screen is deliberately almost empty. It is shown to someone who has
/// just been told they are overloaded, and every element on it is one more
/// thing to process instead of breathe through.
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

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: KoreMotion.breathCycle,
  )..repeat();

  /// Guards against popping twice. See [_onSession].
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    // The session is started by the caller before this route is pushed.
    // Mutating it here would notify listeners during the build phase and
    // mark the dashboard's AnimatedBuilder dirty mid-build.
    widget.session.addListener(_onSession);
  }

  void _onSession() {
    if (!mounted || _leaving) return;

    if (!widget.session.resetActive) {
      _leaving = true;
      // Stop listening the instant we decide to leave. `push` completes as
      // soon as pop() is called, so the caller pushes the check-in while this
      // route is still animating out and still mounted - and the session keeps
      // notifying at 4 Hz throughout. Without this, the next notification
      // called maybePop() again and closed the check-in instead.
      widget.session.removeListener(_onSession);
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

  /// Maps position within the cycle to a breath phase and a 0-1 scale.
  (String, double) _phase(double t) {
    const span = KoreBreath.maxScale - KoreBreath.minScale;
    final pos = t * KoreMotion.breathCycle.inSeconds;
    if (pos < 4) {
      return ('Breathe in', KoreBreath.minScale + span * (pos / _phaseSeconds));
    }
    if (pos < 8) return ('Hold', KoreBreath.maxScale);
    if (pos < 12) {
      return (
        'Breathe out',
        KoreBreath.maxScale - span * ((pos - 8) / _phaseSeconds)
      );
    }
    return ('Hold', KoreBreath.minScale);
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final t = session.resetSecondsRemaining;
    final text = Theme.of(context).textTheme;
    final k = context.kore;

    return Scaffold(
      backgroundColor: k.canvas,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Sized off the shorter axis, so a landscape phone or a short
            // desktop window shrinks the circle rather than clipping it.
            final diameter = KoreBreath.diameterFor(
                constraints.biggest.shortestSide.isFinite
                    ? constraints.biggest.shortestSide
                    : 320);

            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: KoreSpace.xl),
                    Text('RESET PROTOCOL',
                        style: text.labelMedium
                            ?.copyWith(letterSpacing: KoreType.trackedEyebrow)),
                    const SizedBox(height: KoreSpace.xxxl),
                    // Not gated on reduced-motion: the expansion *is* the
                    // instruction. Removing it would leave a word with no
                    // pacing behind it.
                    AnimatedBuilder(
                      animation: _controller,
                      builder: (context, _) {
                        final (label, scale) = _phase(_controller.value);
                        return Column(
                          children: [
                            SizedBox(
                              width: diameter,
                              height: diameter,
                              child: Center(
                                child: Transform.scale(
                                  scale: scale,
                                  child: Container(
                                    width: diameter,
                                    height: diameter,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: k.calm.withValues(
                                          alpha: KoreBreath.fillAlpha),
                                      border: Border.all(
                                        color: k.calm.withValues(
                                            alpha: KoreBreath.borderAlpha),
                                        width: KoreBreath.borderWidth,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: KoreSpace.xl),
                            // Fixed height so the timer below does not shift
                            // as the phase word changes length.
                            SizedBox(
                              height: 30,
                              child: Text(label, style: text.headlineMedium),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: KoreSpace.xxl),
                    Text(
                      '0:${t.toString().padLeft(2, '0')}',
                      style: KoreType.numerals(
                          fontSize: KoreType.size28, color: k.textSecondary),
                    ),
                    const SizedBox(height: KoreSpace.xl),
                    TextButton(
                      onPressed: () => session.cancelReset(),
                      child: const Text('End early'),
                    ),
                    const SizedBox(height: KoreSpace.xl),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
