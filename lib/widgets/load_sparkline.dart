import 'package:flutter/material.dart';

import '../theme/kore_theme.dart';

/// Rolling history of the Cognitive Load Index.
///
/// The gauge answers "how loaded am I now"; this answers "and where was I
/// heading", which is what makes a reset visibly work.
class LoadSparkline extends StatelessWidget {
  /// Oldest to newest, 0-100.
  final List<double> values;

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
          // and the gauge always agree on what the state is.
          trace: values.isEmpty ? k.unmeasured : k.forLoad(values.last),
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> values;
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

    final path = Path()..moveTo(0, y(values.first));
    for (var i = 1; i < values.length; i++) {
      path.lineTo(i * dx, y(values[i]));
    }

    // Soft fill under the trace for weight.
    final fill = Path.from(path)
      ..lineTo((values.length - 1) * dx, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            trace.withValues(alpha: KoreSparkline.fillAlphaTop),
            trace.withValues(alpha: 0.0),
          ],
        ).createShader(Offset.zero & size),
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = KoreSparkline.strokeWidth
        ..strokeJoin = StrokeJoin.round
        ..color = trace,
    );

    canvas.drawCircle(
      Offset((values.length - 1) * dx, y(values.last)),
      KoreSparkline.headRadius,
      Paint()..color = trace,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.trace != trace ||
      old.rule != rule ||
      old.values.length != values.length ||
      (values.isNotEmpty &&
          old.values.isNotEmpty &&
          old.values.last != values.last);
}
