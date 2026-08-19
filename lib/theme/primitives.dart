import 'package:flutter/painting.dart';

/// Layer 1 of the token system: raw values with no assigned meaning.
///
/// Nothing outside `lib/theme/` should import this file. Widgets read the
/// semantic layer (`KoreColors`, `KoreType`, `KoreSpace`) so that a value can
/// be retuned here without a hunt through the UI, and so that light and dark
/// can point the same role at different primitives.
class KoreInk {
  KoreInk._();

  // A warm neutral ramp rather than true grey. KORE's type is a warm cream;
  // neutral grey underneath it reads faintly blue, which fights the palette.
  static const Color x00 = Color(0xFF0B0A09);
  static const Color x05 = Color(0xFF12100F);
  static const Color x10 = Color(0xFF1A1817);
  static const Color x20 = Color(0xFF232120);
  static const Color x30 = Color(0xFF322F2D);
  static const Color x40 = Color(0xFF423E3B);
  static const Color x50 = Color(0xFF6B6560);
  static const Color x60 = Color(0xFF8C857E);
  static const Color x70 = Color(0xFFB0A89D);
  static const Color x80 = Color(0xFFD5CEC3);
  static const Color x90 = Color(0xFFF0EBE1);
  static const Color x95 = Color(0xFFFAF7F1);
  static const Color x100 = Color(0xFFFFFFFF);
}

/// The load ramp's hue anchors, each in a bright form for dark grounds and a
/// deep form for light ones. The pairing is deliberate: the ramp keeps the
/// same five hues in both themes, so the *shape* of a reading is identical
/// whichever theme the user is in.
///
/// Hues run cool -> warm rather than green -> red. Green-to-red is the exact
/// axis red-green colour blindness collapses, and it is what the first
/// version of this ramp used: sampled at 0 and 25 it separated by a CIE
/// deltaE of 4.6 under simulated deuteranopia, i.e. not at all. Traversing
/// teal -> sage -> ochre -> amber -> rust adds a blue-yellow component, which
/// is the axis every common deficiency preserves.
///
/// See `docs/design/design-system.md` for the measured figures and
/// `test/widgets/load_ramp_test.dart` for the assertions that hold them.
class KoreBrand {
  KoreBrand._();

  /// The identity colours. These are the two the product is drawn in and are
  /// unchanged from the original palette.
  static const Color rust = Color(0xFFCF5F3C);
  static const Color sage = Color(0xFF8DA48B);

  static const Color tealBright = Color(0xFF4FA9A2);
  static const Color tealDeep = Color(0xFF2C7A73);

  static const Color sageBright = Color(0xFF8DBE85);
  static const Color sageDeep = Color(0xFF4F7C43);

  static const Color ochreBright = Color(0xFFE0C566);
  static const Color ochreDeep = Color(0xFF8A6A1E);

  static const Color amberBright = Color(0xFFF4A45F);
  static const Color amberDeep = Color(0xFFA85218);

  static const Color rustBright = Color(0xFFE85E42);
  static const Color rustDeep = Color(0xFFA93520);
}
