/// Band powers for one analysis frame, in microvolts squared.
///
/// Normalisation is one-sided and window-corrected, calibrated so that a pure
/// sine of amplitude A lying inside a band reports that band's power as
/// `A^2 / 2` - the sine's mean square. A 50 uV, 10 Hz tone therefore reads
/// alpha = 1250 uV^2, which is what the unit tests assert.
class BandPowers {
  /// 4.0 - 7.5 Hz (bins 8..15 at 0.5 Hz spacing).
  final double theta;

  /// 8.0 - 12.0 Hz (bins 16..24).
  final double alpha;

  /// Summed power across every analysed bin, for reference and sanity checks.
  final double total;

  /// Monotonic counter of completed frames since the last reset.
  final int frameIndex;

  const BandPowers({
    required this.theta,
    required this.alpha,
    required this.total,
    required this.frameIndex,
  });

  @override
  String toString() => 'BandPowers(theta: ${theta.toStringAsFixed(1)}, '
      'alpha: ${alpha.toStringAsFixed(1)}, frame: $frameIndex)';
}
