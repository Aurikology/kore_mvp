import 'dart:math' as math;

import 'metrics.dart';

/// Layer 3: tokens that belong to one component.
///
/// These exist so the responsive layouts can resize a component without
/// inventing numbers. A gauge at 148 and a gauge at 240 are the same gauge;
/// only the diameter is an input, and everything else is derived from it here
/// rather than guessed at the call site.

/// Minimum interactive size, in logical pixels. Both platform guidelines land
/// within a point of this; taking the larger is free.
const double kMinTouchTarget = 48;

class KoreGauge {
  KoreGauge._();

  /// The arc opens downward, leaving a 90 degree gap at the bottom. The gap
  /// is where the eye enters, and it keeps the numeral optically centred.
  static const double startAngle = math.pi * 0.75; // 135 deg
  static const double sweep = math.pi * 1.5; // 270 deg

  /// Fraction of the sweep at which the strain threshold sits. Kept as a
  /// fraction rather than a constant so the tick tracks
  /// `CognitiveLoadIndex.kStrainEnter` if that is ever retuned.
  static double thresholdFraction(double strainEnter) =>
      (strainEnter / 100).clamp(0.0, 1.0);

  /// Proportional stroke, so the ring reads with the same weight whether it
  /// is filling a phone or sitting in a desktop column.
  static double stroke(double diameter) => (diameter * 0.076).clamp(9.0, 18.0);

  static double numeralSize(double diameter) => diameter * 0.30;

  static double captionGap(double diameter) => diameter * 0.02 + 2;

  /// Diameter for the space available. The gauge is the hero on a phone and
  /// takes most of the width; on a desktop it stops growing, because a
  /// 400px number is not more informative than a 240px one.
  static double diameterFor(double availableWidth, KoreWindow window) {
    final cap = switch (window) {
      KoreWindow.compact => 260.0,
      KoreWindow.medium => 208.0,
      KoreWindow.expanded => 240.0,
    };
    final share = window == KoreWindow.compact ? 0.68 : 0.42;
    return (availableWidth * share).clamp(132.0, cap);
  }
}

class KoreSparkline {
  KoreSparkline._();

  static const double strokeWidth = 2;
  static const double headRadius = 3.5;

  /// Dash period and mark for the threshold rule, so it reads as a reference
  /// line rather than as another series.
  static const double dashPeriod = 10;
  static const double dashMark = 5;

  static const double fillAlphaTop = 0.22;

  /// Short enough to stay a glance and not a chart. Taller on a phone
  /// because it is the only trend surface there.
  static double height(KoreWindow window) => switch (window) {
        KoreWindow.compact => 72,
        KoreWindow.medium => 64,
        KoreWindow.expanded => 76,
      };
}

class KoreBreath {
  KoreBreath._();

  /// Scale at the bottom and top of a breath. The 0.6 floor keeps the circle
  /// large enough to follow with peripheral vision, so the user can close
  /// their eyes on the exhale and still catch the turn.
  static const double minScale = 0.6;
  static const double maxScale = 1.0;

  static const double fillAlpha = 0.12;
  static const double borderAlpha = 0.7;
  static const double borderWidth = 2;

  /// Sized off the shorter axis so a landscape phone shrinks it rather than
  /// clipping it.
  static double diameterFor(double shortestSide) =>
      (shortestSide * 0.52).clamp(120.0, 240.0);
}

class KoreCheckIn {
  KoreCheckIn._();

  /// The 1-5 buttons. Floor is the touch minimum; they grow with the sheet
  /// so the row stays evenly divided instead of pooling in the middle.
  static double optionDiameter(double rowWidth) =>
      ((rowWidth - 4 * KoreSpace.xs) / 5).clamp(kMinTouchTarget, 60.0);
}
