import 'dart:math' as math;

import 'band_powers.dart';
import 'dsp_engine.dart';

enum LoadState {
  /// Collecting the personal baseline; no index is meaningful yet.
  calibrating,

  /// Baseline established, load within normal range.
  steady,

  /// Sustained elevated load - a reset is recommended.
  strain,
}

/// Turns band powers into KORE's 0-100 Cognitive Load Index.
///
/// The index is the log theta/alpha ratio measured against a personal
/// baseline, squashed through a logistic. Frontal theta rises with mental
/// workload while alpha is suppressed, so the ratio moves twice as fast as
/// either band alone. Using a *ratio* rather than raw alpha amplitude is what
/// makes the number robust to electrode impedance, amplifier gain, and window
/// constants - all of which cancel.
///
///   r   = ln((P_theta + eps) / (P_alpha + eps))
///   CLI = 100 / (1 + exp(-((r - mu) - C) / K))
///
/// This is policy rather than arithmetic, so it deliberately lives in Dart
/// even when the band powers come from C++ - it is the part that gets tuned.
class CognitiveLoadIndex {
  // --- Tuning constants. Kept named and at the top because these are what
  // you retune against the on-screen curve, and burying them makes that a
  // recompile-and-hunt exercise instead of a 90-second one. ---

  /// Logistic scale, in log-ratio units. Larger = less sensitive.
  static const double kScale = 1.6;

  /// Baseline offset, so a calm baseline reads ~27 rather than 50 - leaving
  /// headroom to show load climbing.
  static const double kOffset = 1.6;

  /// EMA smoothing at the 4 Hz frame rate (tau ~= 2.1 s).
  static const double kEmaAlpha = 0.12;

  /// Baseline capture duration.
  static const double kCalibrationSeconds = 15.0;

  /// Two thresholds, never one - a single threshold flickers on screen.
  static const double kStrainEnter = 70.0;
  static const double kStrainExit = 60.0;

  /// Frames the index must stay above [kStrainEnter] before strain latches.
  static const int kStrainDwellFrames = 20; // 5 s at 4 Hz

  static const double _eps = 1e-9;

  final int _calibrationFrames =
      (kCalibrationSeconds * DspConfig.framesPerSecond).round();

  final List<double> _baselineSamples = [];
  double? _mu;

  double _cli = 0;
  double _lastR = 0;
  bool _hasCli = false;
  int _framesAboveEnter = 0;
  LoadState _state = LoadState.calibrating;

  /// Smoothed index, 0-100. Meaningless until [state] leaves
  /// [LoadState.calibrating].
  double get value => _cli;

  LoadState get state => _state;

  bool get isCalibrated => _mu != null;

  /// 0.0 -> 1.0 through the baseline capture.
  double get calibrationProgress => _mu != null
      ? 1.0
      : (_baselineSamples.length / _calibrationFrames).clamp(0.0, 1.0);

  double get secondsRemainingInCalibration => _mu != null
      ? 0
      : ((_calibrationFrames - _baselineSamples.length) /
              DspConfig.framesPerSecond)
          .clamp(0, double.infinity);

  // Debug readouts for the on-screen overlay.
  double get rawLogRatio => _lastR;
  double get baseline => _mu ?? double.nan;
  double get deviation => _mu == null ? double.nan : _lastR - _mu!;

  /// Feed one analysis frame. Call once per [BandPowers] produced.
  void update(BandPowers p) {
    final r = math.log((p.theta + _eps) / (p.alpha + _eps));
    _lastR = r;

    if (_mu == null) {
      _baselineSamples.add(r);
      if (_baselineSamples.length >= _calibrationFrames) {
        _mu = _baselineSamples.reduce((a, b) => a + b) / _baselineSamples.length;
        _state = LoadState.steady;
      }
      return;
    }

    final raw = 100.0 / (1.0 + math.exp(-((r - _mu!) - kOffset) / kScale));
    // Guard the whole path: a NaN here would propagate into the gauge and
    // paint nothing at all.
    final safe = raw.isFinite ? raw.clamp(0.0, 100.0) : _cli;

    _cli = _hasCli ? _cli + kEmaAlpha * (safe - _cli) : safe;
    _hasCli = true;

    _updateState();
  }

  void _updateState() {
    if (_state == LoadState.strain) {
      if (_cli < kStrainExit) {
        _state = LoadState.steady;
        _framesAboveEnter = 0;
      }
      return;
    }

    if (_cli >= kStrainEnter) {
      _framesAboveEnter++;
      if (_framesAboveEnter >= kStrainDwellFrames) {
        _state = LoadState.strain;
      }
    } else {
      _framesAboveEnter = 0;
    }
  }

  /// Drop the baseline and re-enter calibration, keeping the current index
  /// on screen until a new baseline lands.
  void recalibrate() {
    _baselineSamples.clear();
    _mu = null;
    _framesAboveEnter = 0;
    _state = LoadState.calibrating;
  }

  void reset() {
    recalibrate();
    _cli = 0;
    _hasCli = false;
    _lastR = 0;
  }
}
