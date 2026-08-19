import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/kore_theme.dart';

/// Arc gauge for the Cognitive Load Index.
///
/// Hand-rolled rather than pulled from a charting package: this gauge *is*
/// the product surface, and a dependency would mean a generic look, an
/// unvalidated Windows desktop build, and a fight to bend its defaults into
/// KORE's palette - for about sixty lines of saved code.
///
/// Four channels carry the reading, only one of which is colour: the numeral,
/// the caption, the fraction of the arc that is filled, and the tick at the
/// strain threshold. A user who cannot separate the ramp's hues loses nothing
/// they need.
class LoadMeter extends StatelessWidget {
  /// 0-100. Ignored while [calibrating].
  final double value;

  final bool calibrating;

  /// Seconds left in baseline capture, shown while [calibrating].
  final int calibrationSecondsRemaining;

  /// Index value the tick is drawn at, so the number has a visible frame of
  /// reference rather than being an unanchored 0-100.
  final double strainThreshold;

  final double size;

  const LoadMeter({
    super.key,
    required this.value,
    this.calibrating = false,
    this.calibrationSecondsRemaining = 0,
    this.strainThreshold = 70,
    this.size = 240,
  });

  @override
  Widget build(BuildContext context) {
    final k = context.kore;
    final text = Theme.of(context).textTheme;
    // Routed through forLoad so an uncalibrated gauge can never paint itself
    // calm: with no baseline there is no reading to colour.
    final color = k.forLoad(value, measured: !calibrating);
    final numeral = KoreGauge.numeralSize(size);

    return Semantics(
      container: true,
      label: calibrating
          ? 'Establishing your baseline, '
              '$calibrationSecondsRemaining seconds remaining'
          : 'Cognitive load ${value.round()} out of 100',
      excludeSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: TweenAnimationBuilder<double>(
          // The index updates at 4 Hz; easing between frames makes it read as
          // continuous rather than stepped.
          duration: KoreMotion.respecting(context, KoreMotion.gauge),
          curve: KoreMotion.enter,
          tween: Tween(begin: 0, end: calibrating ? 0 : value.clamp(0, 100)),
          builder: (context, animated, _) {
            return CustomPaint(
              painter: _MeterPainter(
                value: animated,
                color: color,
                track: k.border,
                tick: k.textSecondary,
                thresholdFraction:
                    KoreGauge.thresholdFraction(strainThreshold),
                indeterminate: calibrating,
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (calibrating) ...[
                      Text(
                        'CALIBRATING',
                        style: text.labelMedium
                            ?.copyWith(letterSpacing: KoreType.trackedLabel),
                      ),
                      SizedBox(height: KoreGauge.captionGap(size)),
                      Text(
                        '${calibrationSecondsRemaining}s',
                        style: KoreType.numerals(
                            fontSize: numeral * 0.56, color: color),
                      ),
                    ] else ...[
                      Text(
                        animated.round().toString(),
                        style:
                            KoreType.numerals(fontSize: numeral, color: color),
                      ),
                      SizedBox(height: KoreGauge.captionGap(size)),
                      Text(
                        'COGNITIVE LOAD',
                        style: text.labelMedium
                            ?.copyWith(letterSpacing: KoreType.trackedLabel),
                      ),
                    ],
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

class _MeterPainter extends CustomPainter {
  final double value;
  final Color color;
  final Color track;
  final Color tick;
  final double thresholdFraction;
  final bool indeterminate;

  _MeterPainter({
    required this.value,
    required this.color,
    required this.track,
    required this.tick,
    required this.thresholdFraction,
    required this.indeterminate,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = KoreGauge.stroke(size.shortestSide);
    final arcRect = (Offset.zero & size).deflate(stroke / 2 + 6);

    canvas.drawArc(
      arcRect,
      KoreGauge.startAngle,
      KoreGauge.sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = track,
    );

    if (indeterminate) return;

    canvas.drawArc(
      arcRect,
      KoreGauge.startAngle,
      KoreGauge.sweep * (value / 100).clamp(0.0, 1.0),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );

    final angle = KoreGauge.startAngle + KoreGauge.sweep * thresholdFraction;
    final center = arcRect.center;
    final r = arcRect.width / 2;
    final unit = Offset(math.cos(angle), math.sin(angle));

    canvas.drawLine(
      center + unit * (r - stroke / 2 - 3),
      center + unit * (r + stroke / 2 + 3),
      Paint()
        ..color = tick.withValues(alpha: 0.6)
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_MeterPainter old) =>
      old.value != value ||
      old.color != color ||
      old.track != track ||
      old.tick != tick ||
      old.thresholdFraction != thresholdFraction ||
      old.indeterminate != indeterminate;
}
