import 'dart:math' as math;
import 'dart:typed_data';

/// Periodic (DFT-even) Hann window: `w[n] = 0.5 * (1 - cos(2*pi*n/N))`.
///
/// Periodic, dividing by N - not the symmetric variant that divides by N-1.
/// The distinction is not cosmetic: for the periodic window
/// `sum(w[n]^2) == 3N/8` exactly, which is what makes the power
/// normalisation in [hannSumSquares] an exact constant rather than an
/// empirical fudge factor. It also gives a free unit-test anchor
/// (N=512 -> 192.0).
Float64List hannPeriodic(int n) {
  final w = Float64List(n);
  for (var i = 0; i < n; i++) {
    w[i] = 0.5 * (1 - math.cos(2 * math.pi * i / n));
  }
  return w;
}

/// Closed form of `sum(w[n]^2)` for the periodic Hann window of length [n].
double hannSumSquares(int n) => 3.0 * n / 8.0;
