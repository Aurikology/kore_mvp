import 'dart:typed_data';

import 'band_powers.dart';
import 'biquad.dart';
import 'dsp_engine.dart';
import 'goertzel.dart';
import 'hann.dart';

/// Pure-Dart reference implementation of the KORE signal chain.
///
/// Per sample:  DC blocker -> 60 Hz notch -> ring buffer.
/// Every [DspConfig.hopSize] samples, once the ring is full: window with a
/// periodic Hann and run a Goertzel bank over the theta and alpha bins.
///
/// Runs on the host VM under `flutter test` with no native library and no
/// Flutter binding, which is what makes the DSP directly testable.
class DartDspEngine implements DspEngine {
  final int _n = DspConfig.windowSize;
  final int _hop = DspConfig.hopSize;

  final DcBlocker _dc = DcBlocker(fs: DspConfig.sampleRateHz);
  late final Biquad _notch = Biquad.notch(
    DspConfig.sampleRateHz,
    DspConfig.mainsHz,
    DspConfig.mainsQ,
  );

  late final Float64List _window = hannPeriodic(_n);
  late final double _sumW2 = hannSumSquares(_n);

  /// Circular buffer of filtered samples.
  late final Float64List _ring = Float64List(_n);
  int _writeIndex = 0;
  int _samplesSeen = 0;
  int _samplesSinceFrame = 0;

  /// Time-ordered scratch copy handed to the Goertzel bank. Allocated once.
  late final Float64List _scratch = Float64List(_n);

  BandPowers? _pending;
  int _frameIndex = 0;
  double _lastFiltered = 0;

  @override
  String get backendLabel => 'Dart DSP';

  @override
  double get lastFiltered => _lastFiltered;

  @override
  void pushBlock(List<double> microvolts) {
    for (final raw in microvolts) {
      final filtered = _notch.process(_dc.process(raw));
      _lastFiltered = filtered;

      _ring[_writeIndex] = filtered;
      _writeIndex = (_writeIndex + 1) % _n;
      if (_samplesSeen < _n) _samplesSeen++;
      _samplesSinceFrame++;

      if (_samplesSeen >= _n && _samplesSinceFrame >= _hop) {
        _samplesSinceFrame = 0;
        _pending = _computeFrame();
      }
    }
  }

  @override
  BandPowers? takeFrame() {
    final f = _pending;
    _pending = null;
    return f;
  }

  BandPowers _computeFrame() {
    // Unwrap the ring into time order. _writeIndex is the oldest sample once
    // the buffer has filled.
    for (var i = 0; i < _n; i++) {
      _scratch[i] = _ring[(_writeIndex + i) % _n];
    }

    // One-sided, window-corrected power normalisation. Calibrated so a pure
    // sine of amplitude A inside the band reports A^2/2. The factor of 2
    // accounts for summing only positive-frequency bins; dividing by
    // N * sum(w^2) removes the window's power gain.
    final scale = 2.0 / (_n * _sumW2);

    var theta = 0.0;
    for (var k = DspConfig.thetaBinLo; k <= DspConfig.thetaBinHi; k++) {
      theta += goertzelMagSq(_scratch, _window, k, _n);
    }

    var alpha = 0.0;
    for (var k = DspConfig.alphaBinLo; k <= DspConfig.alphaBinHi; k++) {
      alpha += goertzelMagSq(_scratch, _window, k, _n);
    }

    return BandPowers(
      theta: theta * scale,
      alpha: alpha * scale,
      total: (theta + alpha) * scale,
      frameIndex: _frameIndex++,
    );
  }

  @override
  void reset() {
    _dc.reset();
    _notch.reset();
    _ring.fillRange(0, _n, 0);
    _writeIndex = 0;
    _samplesSeen = 0;
    _samplesSinceFrame = 0;
    _pending = null;
    _frameIndex = 0;
    _lastFiltered = 0;
  }

  @override
  void dispose() {}
}
