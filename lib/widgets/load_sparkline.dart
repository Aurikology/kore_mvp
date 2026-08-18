import 'package:flutter/material.dart';

import '../theme.dart';
import 'load_meter.dart';

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
    this.height = 88,
    this.thresholdLine,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparklinePainter(
          values: values,
          thresholdLine: thresholdLine,
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final double? thresholdLine;

  _SparklinePainter({required this.values, this.thresholdLine});

  @override
  void paint(Canvas canvas, Size size) {
    double y(double v) => size.height * (1 - (v / 100).clamp(0.0, 1.0));

    if (thresholdLine != null) {
      final paint = Paint()
        ..color = KoreTheme.border
        ..strokeWidth = 1;
      final yy = y(thresholdLine!);
      // Dashed, so it reads as a reference rather than as data.
      for (double x = 0; x < size.width; x += 10) {
        canvas.drawLine(Offset(x, yy), Offset(x + 5, yy), paint);
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

    final latestColor = LoadMeter.colorFor(values.last);

    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            latestColor.withValues(alpha: 0.22),
            latestColor.withValues(alpha: 0.0),
          ],
        ).createShader(Offset.zero & size),
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = latestColor,
    );

    canvas.drawCircle(
      Offset((values.length - 1) * dx, y(values.last)),
      3.5,
      Paint()..color = latestColor,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values.length != values.length ||
      (values.isNotEmpty && old.values.isNotEmpty &&
          old.values.last != values.last);
}
