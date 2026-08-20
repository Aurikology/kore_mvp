import 'package:flutter/material.dart';

/// 4pt spacing scale. Every gap in the app is one of these, so vertical
/// rhythm is a property of the system rather than of whoever last touched a
/// widget.
class KoreSpace {
  KoreSpace._();

  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 40;
  static const double huge = 56;
}

class KoreRadius {
  KoreRadius._();

  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;

  /// Anything larger than half the height gives a stadium. Used for buttons
  /// and chips.
  static const double pill = 999;
}

/// Depth is expressed as a change of ground, not as a shadow.
///
/// On the dark theme a drop shadow is invisible against a near-black canvas,
/// so the three levels are three surface tints plus a hairline border. On the
/// light theme the same three tints are nearly identical, so there a soft
/// shadow does the separating instead. Both are the same three levels; only
/// the mechanism differs, which is why this is a token and not an ad-hoc
/// decoration at each call site.
class KoreElevation {
  KoreElevation._();

  /// Level 0 is the canvas, level 1 the surface, level 2 the card. Those
  /// colours live on `KoreColors`; this is the shadow half of the pair.
  static List<BoxShadow> shadow(Brightness brightness, int level) {
    if (brightness == Brightness.dark || level == 0) return const [];
    return [
      BoxShadow(
        color: const Color(0xFF3B332A).withValues(alpha: 0.06 * level),
        blurRadius: 8.0 * level,
        offset: Offset(0, 2.0 * level),
      ),
    ];
  }
}

/// Type scale and the two bundled families.
///
/// Fraunces (serif) is reserved for moments the product wants to feel
/// considered; Space Grotesk carries everything functional. Fonts are
/// bundled assets, never fetched, so rendering does not depend on a network.
class KoreType {
  KoreType._();

  static const String sans = 'SpaceGrotesk';
  static const String serif = 'Fraunces';

  // A ~1.2 ratio scale. Body sits at 16 so the app is readable at arm's
  // length on a phone without the user pinching.
  static const double size10 = 10;
  static const double size11 = 11;
  static const double size12 = 12;
  static const double size14 = 14;
  static const double size16 = 16;
  static const double size18 = 18;
  static const double size20 = 20;
  static const double size24 = 24;
  static const double size28 = 28;
  static const double size36 = 36;
  static const double size48 = 48;

  /// Tracking for the small all-caps labels that head every panel.
  static const double trackedLabel = 1.4;
  static const double trackedEyebrow = 2.0;

  static TextStyle sansStyle({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? height,
    double? letterSpacing,
  }) =>
      TextStyle(
        fontFamily: sans,
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
      );

  static TextStyle serifStyle({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? height,
  }) =>
      TextStyle(
        fontFamily: serif,
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        height: height,
      );

  /// Tabular figures for any number that updates in place. Space Grotesk has
  /// them, so the index does not jitter as it ticks at 4 Hz.
  static TextStyle numerals({
    required double fontSize,
    FontWeight fontWeight = FontWeight.w700,
    required Color color,
  }) =>
      TextStyle(
        fontFamily: sans,
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
        height: 1.0,
      );
}

/// Motion is deliberately short and deliberately dull.
///
/// The user arrives already overloaded; anything that draws the eye without
/// carrying information is a cost. The only long animation in the product is
/// the breathing pacer, and that one *is* the information.
class KoreMotion {
  KoreMotion._();

  static const Duration quick = Duration(milliseconds: 120);
  static const Duration standard = Duration(milliseconds: 240);

  /// The gauge eases between 4 Hz frames so the needle reads as continuous
  /// rather than stepped. Slightly longer than [standard] on purpose.
  static const Duration gauge = Duration(milliseconds: 260);

  /// One full box-breathing cycle: inhale 4, hold 4, exhale 4, hold 4.
  static const Duration breathCycle = Duration(seconds: 16);

  static const Curve enter = Curves.easeOut;
  static const Curve exit = Curves.easeIn;

  /// Zero when the platform asks for reduced motion. Only decorative easing
  /// goes through here - the breathing pacer keeps its timing either way,
  /// because pacing a breath is the function, not the flourish.
  static Duration respecting(BuildContext context, Duration d) =>
      MediaQuery.maybeDisableAnimationsOf(context) == true ? Duration.zero : d;
}

/// Layout classes, named after the surface rather than after a device.
enum KoreWindow {
  /// A phone held one-handed, or a very narrow desktop window.
  compact,

  /// A tablet, a split-screen phone in landscape, or a small desktop window.
  medium,

  /// A desktop window with room for two columns.
  expanded,
}

class KoreBreakpoints {
  KoreBreakpoints._();

  static const double medium = 600;
  static const double expanded = 1000;

  /// The dashboard's second column only earns its place if there is vertical
  /// room for it too; a short, wide window is better served by one column
  /// that scrolls than by two that are clipped.
  static const double twoColumnMinHeight = 640;

  static KoreWindow classify(Size size) {
    if (size.width < medium) return KoreWindow.compact;
    if (size.width < expanded || size.height < twoColumnMinHeight) {
      return KoreWindow.medium;
    }
    return KoreWindow.expanded;
  }

  /// Edge padding by window class. Compact gives up the least width to
  /// margins, because on a phone the gauge is competing for it.
  static double gutter(KoreWindow window) => switch (window) {
        KoreWindow.compact => KoreSpace.lg,
        KoreWindow.medium => KoreSpace.xl,
        KoreWindow.expanded => KoreSpace.xxl,
      };
}
