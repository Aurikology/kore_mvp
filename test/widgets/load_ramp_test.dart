import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:kore/theme/kore_theme.dart';

/// Holds the load ramp to the accessibility claims made for it in
/// `docs/design/design-system.md`.
///
/// The ramp exists to be read by someone who is already overloaded, on a
/// phone, possibly with a colour vision deficiency. Those are claims about
/// measurable quantities, so they are asserted rather than asserted-in-prose.
/// The ramp this replaced failed the second group badly: sampled at 0 and 25
/// it separated by a deltaE of 4.6 under simulated deuteranopia.
void main() {
  group('contrast', () {
    // Large text and graphical objects need 3:1 under WCAG; the numeral and
    // the arc are both. Holding the ramp to 4.5 gives headroom and lets the
    // same colour be used for the small state text without a second token.
    const floor = 4.5;

    void checkRamp(String name, KoreLoadRamp ramp, List<Color> grounds) {
      for (var v = 0; v <= 100; v += 5) {
        final c = ramp.at(v.toDouble());
        for (final g in grounds) {
          expect(_contrast(c, g), greaterThanOrEqualTo(floor),
              reason: '$name at $v on ${_hex(g)} is ${_contrast(c, g)}');
        }
      }
    }

    test('the dark ramp is legible on canvas and card', () {
      checkRamp('dark', KoreLoadRamp.dark,
          [KoreColors.dark.canvas, KoreColors.dark.card]);
    });

    test('the light ramp is legible on canvas and card', () {
      checkRamp('light', KoreLoadRamp.light,
          [KoreColors.light.canvas, KoreColors.light.card]);
    });

    test('body and secondary text clear 4.5:1 in both themes', () {
      for (final k in [KoreColors.dark, KoreColors.light]) {
        for (final ground in [k.canvas, k.surface, k.card]) {
          expect(_contrast(k.textPrimary, ground), greaterThanOrEqualTo(4.5));
          expect(_contrast(k.textSecondary, ground), greaterThanOrEqualTo(4.5));
        }
      }
    });
  });

  group('colour vision deficiency', () {
    // Calm and strained are the two readings a decision hangs on. 35 is a
    // wide margin - the ends of both ramps clear it under every simulation
    // with room to spare, and the old sage-to-rust ramp did not.
    const minSeparation = 35.0;

    for (final entry in {
      'dark': KoreLoadRamp.dark,
      'light': KoreLoadRamp.light,
    }.entries) {
      test('${entry.key}: the ends stay apart for every deficiency', () {
        final calm = entry.value.at(0);
        final strained = entry.value.at(100);

        for (final kind in _Deficiency.values) {
          final d = _deltaE(_simulate(calm, kind), _simulate(strained, kind));
          expect(d, greaterThanOrEqualTo(minSeparation),
              reason: '${entry.key} ends under ${kind.name} separate by $d');
        }
      });
    }
  });

  group('ramp behaviour', () {
    test('clamps outside 0-100 rather than extrapolating', () {
      expect(KoreLoadRamp.dark.at(-40), KoreLoadRamp.dark.stops.first);
      expect(KoreLoadRamp.dark.at(180), KoreLoadRamp.dark.stops.last);
    });

    test('an unmeasured reading never borrows a ramp colour', () {
      // A calibrating gauge showing the calm end would be a claim the app
      // has no baseline to support.
      const k = KoreColors.dark;
      expect(k.forLoad(0, measured: false), k.unmeasured);
      expect(k.forLoad(95, measured: false), k.unmeasured);
      for (final stop in k.loadRamp.stops) {
        expect(stop, isNot(k.unmeasured));
      }
    });
  });
}

// --- Colour science, kept local to the test ------------------------------
//
// Small enough to inline and worth far more than a dependency would be: this
// is the only place in the project that needs it.

String _hex(Color c) =>
    '#${((c.r * 255).round() << 16 | (c.g * 255).round() << 8 | (c.b * 255).round()).toRadixString(16).padLeft(6, '0')}';

double _toLinear(double channel) => channel <= 0.04045
    ? channel / 12.92
    : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    0.2126 * _toLinear(c.r) + 0.7152 * _toLinear(c.g) + 0.0722 * _toLinear(c.b);

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// CIE L*a*b* from sRGB, D65.
List<double> _lab(Color c) {
  final r = _toLinear(c.r);
  final g = _toLinear(c.g);
  final b = _toLinear(c.b);

  final x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
  final y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  final z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;

  double f(double t) =>
      t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;

  return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))];
}

double _deltaE(Color a, Color b) {
  final la = _lab(a);
  final lb = _lab(b);
  return math.sqrt(List.generate(3, (i) => math.pow(la[i] - lb[i], 2))
      .fold<double>(0, (s, v) => s + v));
}

enum _Deficiency { none, protanopia, deuteranopia, tritanopia }

/// Vienot, Brettel and Mollon (1999) dichromat simulation, via
/// Hunt-Pointer-Estevez LMS.
Color _simulate(Color c, _Deficiency kind) {
  if (kind == _Deficiency.none) return c;

  final rgb = [_toLinear(c.r), _toLinear(c.g), _toLinear(c.b)];

  const toLms = [
    [0.31399, 0.63951, 0.04649],
    [0.15537, 0.75789, 0.08670],
    [0.01775, 0.10945, 0.87262],
  ];
  const fromLms = [
    [5.47221, -4.64190, 0.16963],
    [-1.12520, 2.29317, -0.16780],
    [0.02980, -0.19318, 1.16364],
  ];
  final collapse = switch (kind) {
    _Deficiency.protanopia => const [
        [0.0, 1.05118294, -0.05116099],
        [0.0, 1.0, 0.0],
        [0.0, 0.0, 1.0],
      ],
    _Deficiency.deuteranopia => const [
        [1.0, 0.0, 0.0],
        [0.9513092, 0.0, 0.04866992],
        [0.0, 0.0, 1.0],
      ],
    _Deficiency.tritanopia => const [
        [1.0, 0.0, 0.0],
        [0.0, 1.0, 0.0],
        [-0.86744736, 1.86727089, 0.0],
      ],
    _Deficiency.none => const [
        [1.0, 0.0, 0.0],
        [0.0, 1.0, 0.0],
        [0.0, 0.0, 1.0],
      ],
  };

  List<double> apply(List<List<double>> m, List<double> v) => [
        for (final row in m) row[0] * v[0] + row[1] * v[1] + row[2] * v[2],
      ];

  final out = apply(fromLms, apply(collapse, apply(toLms, rgb)));

  double toSrgb(double v) {
    final x = v.clamp(0.0, 1.0);
    return x <= 0.0031308
        ? 12.92 * x
        : 1.055 * math.pow(x, 1 / 2.4).toDouble() - 0.055;
  }

  return Color.from(
      alpha: 1, red: toSrgb(out[0]), green: toSrgb(out[1]), blue: toSrgb(out[2]));
}
