import 'package:flutter/material.dart';

import '../services/signal_quality.dart';
import '../theme/kore_theme.dart';

/// A head seen from above, with a dot per electrode.
///
/// Its only job is to turn "Left pad" into somewhere on the user's face. The
/// labels are deliberately positional and lay rather than 10-20 designators
/// (see [ElectrodeContact]), and a positional label is only useful against a
/// picture - "press the left pad down" needs the user to know which pad the
/// app is calling left.
///
/// **Geometry lives here, not in the model.** `SignalQuality` carries no
/// electrode positions on purpose: nothing in the repo commits to a montage,
/// an electrode count, or a reference, and putting coordinates on
/// [ElectrodeContact] would commit to all three by accident. This widget
/// guesses a placement from the pad's id and falls back to spreading unknown
/// pads evenly across the forehead, which is a drawing decision and is allowed
/// to be wrong in a way a measurement is not.
///
/// No colour-only encoding: each dot is filled when the pad is reading and
/// hollow when it is not, so the picture survives being seen in greyscale, and
/// the word beside it in the list is what actually carries the state.
class PatchDiagram extends StatelessWidget {
  final List<ElectrodeContact> electrodes;

  const PatchDiagram({super.key, required this.electrodes});

  /// Where a known pad sits, in a square running -1 (left, top) to 1. The
  /// origin is the centre of the head; negative y is toward the forehead.
  static const Map<String, Offset> _known = {
    'left': Offset(-0.42, -0.34),
    'right': Offset(0.42, -0.34),
    'centre': Offset(0, -0.44),
    'center': Offset(0, -0.44),
    'band': Offset(0, -0.44),
    'ref': Offset(0, 0.46),
    'reference': Offset(0, 0.46),
  };

  /// Unknown pads spread across the forehead rather than stacking on the
  /// origin. A guess that is visibly a guess beats an overlap that looks like
  /// one pad.
  static Offset placementFor(String id, int index, int count) {
    final known = _known[id];
    if (known != null) return known;
    if (count <= 1) return const Offset(0, -0.44);
    final t = index / (count - 1); // 0..1 across the brow
    return Offset(-0.5 + t, -0.36);
  }

  @override
  Widget build(BuildContext context) {
    final kore = context.kore;
    return AspectRatio(
      aspectRatio: 1,
      child: CustomPaint(
        painter: _HeadPainter(
          electrodes: electrodes,
          outline: kore.borderStrong,
          good: kore.calm,
          attention: kore.accent,
          unmeasured: kore.unmeasured,
        ),
        // Announced as one thing. A screen reader walking twelve unlabelled
        // circles is worse than one that says what the picture is and leaves
        // the states to the list below, which reads them in words anyway.
        child: Semantics(
          label: 'Diagram of where the pads sit on the head',
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _HeadPainter extends CustomPainter {
  final List<ElectrodeContact> electrodes;
  final Color outline;
  final Color good;
  final Color attention;
  final Color unmeasured;

  _HeadPainter({
    required this.electrodes,
    required this.outline,
    required this.good,
    required this.attention,
    required this.unmeasured,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide * 0.36;

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = outline;

    canvas.drawOval(
      Rect.fromCenter(
        center: centre,
        width: radius * 1.72,
        height: radius * 2.0,
      ),
      stroke,
    );

    // The nose. Without it the outline is a circle and "left" is whichever
    // side the user decides it is.
    final noseTop = centre.dy - radius - radius * 0.16;
    final nose = Path()
      ..moveTo(centre.dx - radius * 0.14, centre.dy - radius * 0.98)
      ..lineTo(centre.dx, noseTop)
      ..lineTo(centre.dx + radius * 0.14, centre.dy - radius * 0.98);
    canvas.drawPath(nose, stroke);

    for (var i = 0; i < electrodes.length; i++) {
      final e = electrodes[i];
      final p = PatchDiagram.placementFor(e.id, i, electrodes.length);
      final at = Offset(
        centre.dx + p.dx * radius * 1.6,
        centre.dy + p.dy * radius * 1.8,
      );

      final colour = switch (e.state) {
        ElectrodeContactState.good => good,
        ElectrodeContactState.weak => attention,
        ElectrodeContactState.noContact => attention,
        ElectrodeContactState.unmeasured => unmeasured,
      };

      // Filled means reading. Hollow means nothing is coming through it -
      // which is the same distinction the word beside it makes, drawn in a
      // channel that survives a colourblind user and a greyscale screenshot.
      final filled = e.state == ElectrodeContactState.good ||
          e.state == ElectrodeContactState.weak;

      canvas.drawCircle(
        at,
        radius * 0.13,
        Paint()
          ..color = colour
          ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }
  }

  @override
  bool shouldRepaint(_HeadPainter old) =>
      old.outline != outline ||
      old.good != good ||
      old.attention != attention ||
      old.unmeasured != unmeasured ||
      old.electrodes.length != electrodes.length ||
      _statesDiffer(old.electrodes, electrodes);

  /// Repaint on a change of *band*, not of raw coupling. A ramping electrode
  /// moves its number continuously and the drawing cannot show the difference,
  /// so repainting on the raw value would be sixty repaints a second of an
  /// identical picture.
  static bool _statesDiffer(
      List<ElectrodeContact> a, List<ElectrodeContact> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i].id != b[i].id || a[i].state != b[i].state) return true;
    }
    return false;
  }
}
