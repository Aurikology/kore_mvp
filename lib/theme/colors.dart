import 'package:flutter/material.dart';

import 'load_ramp.dart';
import 'primitives.dart';

/// Layer 2: colour by role, not by name.
///
/// Carried as a [ThemeExtension] rather than as statics on a theme class
/// because the CustomPainters need the resolved colours. A painter has no
/// BuildContext, so the widget above it reads `context.kore` once in `build`
/// and hands the whole object down as a painter field - which also gives
/// `shouldRepaint` a cheap identity check when the theme changes.
@immutable
class KoreColors extends ThemeExtension<KoreColors> {
  /// Behind everything.
  final Color canvas;

  /// Sheets and bars that sit on [canvas].
  final Color surface;

  /// Cards on [surface]. Elevation here is a change of ground, not a shadow -
  /// see [KoreElevation] in metrics.dart.
  final Color card;

  final Color border;
  final Color borderStrong;

  final Color textPrimary;
  final Color textSecondary;

  /// Actions. Distinct from the load ramp on purpose: a button must not
  /// change colour because the reading moved.
  final Color accent;
  final Color onAccent;

  /// The two named ends of the ramp, for anything that needs "recovered" or
  /// "under load" without a numeric reading behind it.
  final Color calm;
  final Color strain;

  /// Nothing measurable yet. Used for the calibrating gauge and for a
  /// statistic with no data behind it, so that "unknown" never borrows the
  /// colour of a good result.
  final Color unmeasured;

  final KoreLoadRamp loadRamp;

  const KoreColors({
    required this.canvas,
    required this.surface,
    required this.card,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.accent,
    required this.onAccent,
    required this.calm,
    required this.strain,
    required this.unmeasured,
    required this.loadRamp,
  });

  static const KoreColors dark = KoreColors(
    canvas: KoreInk.x05,
    surface: KoreInk.x10,
    card: KoreInk.x20,
    border: KoreInk.x30,
    borderStrong: KoreInk.x40,
    textPrimary: KoreInk.x90,
    textSecondary: KoreInk.x70,
    accent: KoreBrand.rust,
    onAccent: KoreInk.x05,
    calm: KoreBrand.tealBright,
    strain: KoreBrand.rustBright,
    unmeasured: KoreInk.x60,
    loadRamp: KoreLoadRamp.dark,
  );

  /// Not an inversion of [dark]. On a light ground the load ramp has to get
  /// *darker* toward strain to stay legible, which is why the ramp keeps a
  /// separate deep variant of each hue rather than reusing the bright one.
  static const KoreColors light = KoreColors(
    canvas: KoreInk.x95,
    surface: KoreInk.x100,
    card: KoreInk.x100,
    border: Color(0xFFE3DCD0),
    borderStrong: Color(0xFFC8BFB1),
    textPrimary: KoreInk.x10,
    textSecondary: KoreInk.x50,
    accent: Color(0xFFB44E2C),
    onAccent: KoreInk.x100,
    calm: KoreBrand.tealDeep,
    strain: KoreBrand.rustDeep,
    unmeasured: KoreInk.x50,
    loadRamp: KoreLoadRamp.light,
  );

  /// Colour for a 0-100 reading, or [unmeasured] when there is no baseline to
  /// measure it against. Routing "no reading yet" through the same call is
  /// what stops a calibrating gauge from ever painting itself calm.
  Color forLoad(double value, {bool measured = true}) =>
      measured ? loadRamp.at(value) : unmeasured;

  @override
  KoreColors copyWith({
    Color? canvas,
    Color? surface,
    Color? card,
    Color? border,
    Color? borderStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? accent,
    Color? onAccent,
    Color? calm,
    Color? strain,
    Color? unmeasured,
    KoreLoadRamp? loadRamp,
  }) =>
      KoreColors(
        canvas: canvas ?? this.canvas,
        surface: surface ?? this.surface,
        card: card ?? this.card,
        border: border ?? this.border,
        borderStrong: borderStrong ?? this.borderStrong,
        textPrimary: textPrimary ?? this.textPrimary,
        textSecondary: textSecondary ?? this.textSecondary,
        accent: accent ?? this.accent,
        onAccent: onAccent ?? this.onAccent,
        calm: calm ?? this.calm,
        strain: strain ?? this.strain,
        unmeasured: unmeasured ?? this.unmeasured,
        loadRamp: loadRamp ?? this.loadRamp,
      );

  @override
  KoreColors lerp(ThemeExtension<KoreColors>? other, double t) {
    if (other is! KoreColors) return this;
    return KoreColors(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      card: Color.lerp(card, other.card, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      calm: Color.lerp(calm, other.calm, t)!,
      strain: Color.lerp(strain, other.strain, t)!,
      unmeasured: Color.lerp(unmeasured, other.unmeasured, t)!,
      loadRamp: KoreLoadRamp.lerp(loadRamp, other.loadRamp, t),
    );
  }
}
