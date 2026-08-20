import 'package:flutter/painting.dart';

import 'primitives.dart';

/// The 0-100 Cognitive Load Index ramp.
///
/// Five hand-placed stops interpolated pairwise, rather than a two-colour
/// `Color.lerp`. A straight lerp from sage to rust passes through a
/// chroma-dead brown around 50 - precisely the range where the reading is
/// most often sitting and where movement most needs to be visible. Placing
/// stops lets the mid-range keep its chroma.
///
/// The ramp is a *supporting* cue and never the only one. The number, the
/// state word, the arc's fill fraction and the threshold tick all carry the
/// same information, so a reading is legible with colour discarded entirely.
class KoreLoadRamp {
  /// Ordered calm -> strained. Positions are 0, 25, 50, 75, 100.
  final List<Color> stops;

  const KoreLoadRamp(this.stops);

  /// For dark grounds. Every stop clears 4.5:1 against both the canvas and
  /// the card surface, so the numeral stays readable at any reading.
  static const KoreLoadRamp dark = KoreLoadRamp([
    KoreBrand.tealBright,
    KoreBrand.sageBright,
    KoreBrand.ochreBright,
    KoreBrand.amberBright,
    KoreBrand.rustBright,
  ]);

  static const KoreLoadRamp light = KoreLoadRamp([
    KoreBrand.tealDeep,
    KoreBrand.sageDeep,
    KoreBrand.ochreDeep,
    KoreBrand.amberDeep,
    KoreBrand.rustDeep,
  ]);

  /// Colour for a 0-100 index reading.
  Color at(double value) {
    final t = (value.clamp(0.0, 100.0) / 100.0) * (stops.length - 1);
    final i = t.floor().clamp(0, stops.length - 2);
    return Color.lerp(stops[i], stops[i + 1], t - i)!;
  }

  static KoreLoadRamp lerp(KoreLoadRamp a, KoreLoadRamp b, double t) =>
      KoreLoadRamp([
        for (var i = 0; i < a.stops.length; i++)
          Color.lerp(a.stops[i], b.stops[i], t)!,
      ]);
}
