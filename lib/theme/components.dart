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

class KoreTrend {
  KoreTrend._();

  /// Days on the dashboard card and on the full screen.
  ///
  /// The card's span is also the window the slope is fitted over, so the
  /// sentence and the bars beneath it can never be describing different
  /// fortnights.
  static const int cardSpan = 14;
  static const int screenSpan = 30;

  /// Taller than the sparkline: this one carries two channels per day and a
  /// bar has to be tall enough for the height difference between two adjacent
  /// days to be visible at all.
  static double height(KoreWindow window) => switch (window) {
        KoreWindow.compact => 96,
        KoreWindow.medium => 88,
        KoreWindow.expanded => 104,
      };

  /// Gap between bars, as a fraction of the slot each day gets. Kept
  /// proportional so thirty days on a phone and fourteen on a desktop column
  /// read as the same chart at two densities.
  static const double barGap = 0.28;
  static const double barMinWidth = 3;

  /// Bars stop widening well before the slot does. In the desktop layout's
  /// right-hand column a fortnight has 40 px per day, and a 40 px bar is a
  /// block rather than a reading - the eye compares heights better across
  /// narrow marks than wide ones.
  static const double barMaxWidth = 24;
  static const double barRadius = 2;

  /// A day carrying less than `DailyLoadLog.minFramesForTrend` is drawn, but
  /// muted, because its mean is dominated by the moment the app happened to be
  /// open. Drawing it is what makes the refusal legible: the user can see
  /// which days did not count rather than being told a number they cannot
  /// locate.
  static const double shortDayAlpha = 0.4;

  /// The day's peak, as a cap above the mean bar. Quieter than the bar because
  /// the mean is the reading and the peak is its context.
  static const double peakAlpha = 0.55;
  static const double peakCapHeight = 2;

  /// The same reference rule the sparkline draws, from one pair of values so
  /// the two charts on the dashboard cannot drift apart.
  static const double dashPeriod = KoreSparkline.dashPeriod;
  static const double dashMark = KoreSparkline.dashMark;

  static double barWidth(double available, int slots) {
    if (slots <= 0) return barMinWidth;
    return ((available / slots) * (1 - barGap))
        .clamp(barMinWidth, barMaxWidth);
  }
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
