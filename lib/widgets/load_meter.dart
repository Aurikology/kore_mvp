import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Arc gauge for the Cognitive Load Index.
///
/// Hand-rolled rather than pulled from a charting package: this gauge *is*
/// the product surface, and a dependency would mean a generic look, an
/// unvalidated Windows desktop build, and a fight to bend its defaults into
/// the rust/sage palette - for about sixty lines of saved code.
class LoadMeter extends StatelessWidget {
  /// 0-100. Ignored while [calibrating].
  final double value;

  final bool calibrating;

  /// Seconds left in baseline capture, shown while [calibrating].
  final int calibrationSecondsRemaining;

  final double size;

  const LoadMeter({
    super.key,
    required this.value,
    this.calibrating = false,
    this.calibrationSecondsRemaining = 0,
    this.size = 260,
  });

  /// Sage when calm, rust under load. Colour carries the same information as
  /// the number, so the state is readable at a glance from across a room.
  static Color colorFor(double value) =>
      Color.lerp(KoreTheme.sage, KoreTheme.rust, (value / 100).clamp(0, 1))!;

  @override
  Widget build(BuildContext context) {
    final color = calibrating ? KoreTheme.textSecondary : colorFor(value);

    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        // The index updates at 4 Hz; easing between frames makes it read as
        // continuous rather than stepped.
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
        tween: Tween(begin: 0, end: calibrating ? 0 : value.clamp(0, 100)),
        builder: (context, animated, _) {
          return CustomPaint(
            painter: _MeterPainter(
              value: animated,
              color: color,
              indeterminate: calibrating,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (calibrating) ...[
                    Text(
                      'CALIBRATING',
                      style: Theme.of(context)
                          .textTheme
                          .labelMedium
                          ?.copyWith(letterSpacing: 1.6),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${calibrationSecondsRemaining}s',
                      style: KoreTheme.numerals(
                          fontSize: size * 0.17,
                          color: KoreTheme.textSecondary),
                    ),
                  ] else ...[
                    Text(
                      animated.round().toString(),
                      style:
                          KoreTheme.numerals(fontSize: size * 0.30, color: color),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'COGNITIVE LOAD',
                      style: Theme.of(context)
                          .textTheme
                          .labelMedium
                          ?.copyWith(letterSpacing: 1.6),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  static const double _startAngle = math.pi * 0.75; // 135 deg
  static const double _sweep = math.pi * 1.5; // 270 deg

  final double value;
  final Color color;
  final bool indeterminate;

  _MeterPainter({
    required this.value,
    required this.color,
    required this.indeterminate,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 14.0;
    final rect = Offset.zero & size;
    final arcRect = rect.deflate(stroke / 2 + 6);

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = KoreTheme.border;

    canvas.drawArc(arcRect, _startAngle, _sweep, false, track);

    if (indeterminate) return;

    final progress = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;

    canvas.drawArc(
      arcRect,
      _startAngle,
      _sweep * (value / 100).clamp(0.0, 1.0),
      false,
      progress,
    );

    // Tick at the strain threshold, so the number has a visible frame of
    // reference rather than being an unanchored 0-100.
    final tickAngle = _startAngle + _sweep * 0.70;
    final center = arcRect.center;
    final r = arcRect.width / 2;
    final inner = center +
        Offset(math.cos(tickAngle), math.sin(tickAngle)) * (r - stroke / 2 - 3);
    final outer = center +
        Offset(math.cos(tickAngle), math.sin(tickAngle)) * (r + stroke / 2 + 3);

    canvas.drawLine(
      inner,
      outer,
      Paint()
        ..color = KoreTheme.textSecondary.withValues(alpha: 0.6)
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_MeterPainter old) =>
      old.value != value ||
      old.color != color ||
      old.indeterminate != indeterminate;
}
