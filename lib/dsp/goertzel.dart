import 'dart:math' as math;
import 'dart:typed_data';

/// Squared magnitude of DFT bin [k] of the windowed signal `x * w`.
///
/// This is the Goertzel algorithm. The result is *exactly* `|X[k]|^2` for the
/// length-[n] DFT - not an approximation - so band powers derived from it are
/// as defensible as an FFT's.
///
/// Chosen over a radix-2 FFT because the index needs 17 of 256 bins. Goertzel
/// is a dozen lines with no bit-reversal, no complex buffers, and none of the
/// classic in-place indexing traps; an FFT would be more code for strictly
/// less clarity at this bin count.
double goertzelMagSq(Float64List x, Float64List w, int k, int n) {
  final coeff = 2 * math.cos(2 * math.pi * k / n);
  double s1 = 0, s2 = 0;

  for (var i = 0; i < n; i++) {
    final s0 = x[i] * w[i] + coeff * s1 - s2;
    s2 = s1;
    s1 = s0;
  }

  return s1 * s1 + s2 * s2 - coeff * s1 * s2;
}
