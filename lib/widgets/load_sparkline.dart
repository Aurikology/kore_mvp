import 'package:flutter/material.dart';

import '../theme/kore_theme.dart';

/// Rolling history of the Cognitive Load Index.
///
/// The gauge answers "how loaded am I now"; this answers "and where was I
/// heading", which is what makes a reset visibly work.
///
/// **A null is a hole, and it is drawn as one.** The app is suspended
/// constantly on a phone, and the minutes it spent not measuring must not be
/// joined up into a line it never observed - a straight segment across a gap
/// reads as a measurement of calm. The trace breaks and picks up on the far
/// side, at the x position the time actually fell at.
class LoadSparkline extends StatelessWidget {
  /// Oldest to newest, 0-100. Null where nothing was measured.
  final List<double?> values;

  final double height;

  /// Drawn as a dashed rule so the strain threshold is legible.
  final double? thresholdLine;

  const LoadSparkline({
    super.key,
    required this.values,
    this.height = 72,
    this.thresholdLine,
  });

  @override
  Widget build(BuildContext context) {
    final k = context.kore;

    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparklinePainter(
          values: values,
          thresholdLine: thresholdLine,
          rule: k.border,
          // The trace takes the colour of the *latest* reading, so the trend
          // and the gauge always agree on what the state is. The latest
          // reading is the last one that exists, not the last slot.
          trace: _latest(values) == null
              ? k.unmeasured
              : k.forLoad(_latest(values)!),
        ),
      ),
    );
  }
}

double? _latest(List<double?> values) {
  for (var i = values.length - 1; i >= 0; i--) {
    if (values[i] != null) return values[i];
  }
  return null;
}

class _SparklinePainter extends CustomPainter {
  final List<double?> values;
  final double? thresholdLine;
  final Color rule;
  final Color trace;

  _SparklinePainter({
    required this.values,
    required this.rule,
    required this.trace,
    this.thresholdLine,
  });

  @override
  void paint(Canvas canvas, Size size) {
    double y(double v) => size.height * (1 - (v / 100).clamp(0.0, 1.0));

    if (thresholdLine != null) {
      final paint = Paint()
        ..color = rule
        ..strokeWidth = 1;
      final yy = y(thresholdLine!);
      // Dashed, so it reads as a reference rather than as data.
      for (double x = 0; x < size.width; x += KoreSparkline.dashPeriod) {
        canvas.drawLine(
            Offset(x, yy), Offset(x + KoreSparkline.dashMark, yy), paint);
      }
    }

    if (values.length < 2) return;

    // Always scale to the full history capacity so the trace advances across
    // the panel as data arrives instead of rescaling under the viewer.
    final dx = size.width / (values.length - 1);

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = KoreSparkline.strokeWidth
      ..strokeJoin = StrokeJoin.round
      ..color = trace;

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          trace.withValues(alpha: KoreSparkline.fillAlphaTop),
          trace.withValues(alpha: 0.0),
        ],
      ).createShader(Offset.zero & size);

    // One path per run of consecutive measurements. Each run keeps the x
    // position its samples actually occupy, so the width of a hole is the
    // duration of the hole rather than a join.
    var i = 0;
    Offset? head;
    while (i < values.length) {
      if (values[i] == null) {
        i++;
        continue;
      }

      final points = <Offset>[];
      while (i < values.length && values[i] != null) {
        points.add(Offset(i * dx, y(values[i]!)));
        i++;
      }
      head = points.last;

      // A single reading with holes either side has no line to draw. It is
      // still a measurement, so it is drawn - as the head dot, below.
      if (points.length < 2) continue;

      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final p in points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }

      canvas.drawPath(
        Path.from(path)
          ..lineTo(points.last.dx, size.height)
          ..lineTo(points.first.dx, size.height)
          ..close(),
        fillPaint,
      );
      canvas.drawPath(path, stroke);
    }

    if (head != null) {
      canvas.drawCircle(head, KoreSparkline.headRadius, Paint()..color = trace);
    }
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.trace != trace ||
      old.rule != rule ||
      old.values.length != values.length ||
      // The last *reading*, not the last slot: an empty list has neither, and
      // a list ending in a hole has only the former.
      _latest(old.values) != _latest(values);
}
