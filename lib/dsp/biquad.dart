import 'dart:math' as math;

/// Direct-form-I biquad section.
///
/// Coefficients are stored already normalised by a0, so [process] is five
/// multiplies and four adds per sample.
class Biquad {
  final double b0, b1, b2, a1, a2;

  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);

  /// RBJ cookbook notch (band-stop) at [f0] Hz with quality factor [q].
  ///
  /// Used to reject 60 Hz mains. Note this contributes almost nothing to the
  /// cognitive load index itself - the Goertzel bank is band-selective and
  /// simply never looks at 60 Hz. It matters for the displayed waveform, and
  /// it matters the day a real electrode is attached.
  factory Biquad.notch(double fs, double f0, double q) {
    final w0 = 2 * math.pi * f0 / fs;
    final cosW0 = math.cos(w0);
    final sinW0 = math.sin(w0);
    final alpha = sinW0 / (2 * q);
    final a0 = 1 + alpha;

    return Biquad(
      1 / a0,
      -2 * cosW0 / a0,
      1 / a0,
      -2 * cosW0 / a0,
      (1 - alpha) / a0,
    );
  }

  double process(double x) {
    final y = b0 * x + b1 * _x1 + b2 * _x2 - a1 * _y1 - a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }

  void reset() {
    _x1 = _x2 = _y1 = _y2 = 0;
  }
}

/// One-pole DC blocker: `y[n] = x[n] - x[n-1] + R*y[n-1]`.
///
/// This one is load-bearing. Without it a standing DC offset leaks through
/// the Hann window's sidelobes into the low theta bins and inflates the
/// index. Cheaper and more numerically forgiving than a biquad highpass.
class DcBlocker {
  final double r;

  double _x1 = 0, _y1 = 0;

  DcBlocker({double fs = 256.0, double cutoffHz = 0.5})
      : r = 1 - 2 * math.pi * cutoffHz / fs;

  double process(double x) {
    final y = x - _x1 + r * _y1;
    _x1 = x;
    _y1 = y;
    return y;
  }

  void reset() {
    _x1 = 0;
    _y1 = 0;
  }
}
