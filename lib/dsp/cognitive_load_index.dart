import 'dart:math' as math;

import 'band_powers.dart';
import 'dsp_engine.dart';
import 'load_profile.dart';

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

  /// Two thresholds, never one - a single threshold flickers on screen. These
  /// are the defaults, and the numbers every published figure is quoted
  /// against; a user with enough history on record gets their own, see
  /// [strainEnter].
  static const double kStrainEnter = 70.0;
  static const double kStrainExit = 60.0;

  /// Frames the index must stay above [strainEnter] before strain latches.
  static const int kStrainDwellFrames = 20; // 5 s at 4 Hz

  // --- Personalisation. All of it is policy, so it lives beside the rest of
  // the tuning rather than inside [LoadProfile], which is a data record. ---

  /// A personal enter threshold sits this far above the user's own mean index,
  /// in their own standard deviations. One sigma puts roughly the top sixth of
  /// their measured time in strain - frequent enough to be a live signal, rare
  /// enough to still mean something.
  static const double kEnterSigma = 1.0;

  /// Distance between enter and exit, taken from the published 70/60 so the
  /// latch has identical hysteresis wherever the thresholds land. Personalise
  /// the position, never the gap: the gap is what stops the state flickering.
  static const double kThresholdGap = kStrainEnter - kStrainExit;

  /// Bounds on personalisation. Outside these the thresholds stop describing
  /// load and start describing whatever the electrode was doing - and an enter
  /// threshold of 98 is indistinguishable from having no threshold at all.
  static const double kEnterFloor = 55.0;
  static const double kEnterCeiling = 85.0;

  /// Frames of personal index history required before the thresholds move at
  /// all. 2,400 is ten minutes at 4 Hz: long enough that a first short session
  /// cannot personalise anything, short enough to matter within day one.
  static const int kFramesBeforePersonalising = 2400;

  /// How far this session's capture may sit from the long-run personal
  /// baseline before it is pulled back toward it, in log-ratio units.
  ///
  /// 0.8 is half the logistic's offset - about 12 index points. A capture
  /// further out than that is far more likely to be a user who sat down
  /// already strained than a genuine shift in their resting ratio, and taking
  /// it at face value is exactly how the app ends up telling someone who is
  /// struggling that they are steady.
  static const double kBaselineTrustBand = 0.8;

  static const double _eps = 1e-9;

  final int _calibrationFrames =
      (kCalibrationSeconds * DspConfig.framesPerSecond).round();

  final List<double> _baselineSamples = [];
  double? _mu;

  LoadProfile _profile;

  double _cli = 0;
  double _lastR = 0;
  bool _hasCli = false;
  int _framesAboveEnter = 0;
  LoadState _state = LoadState.calibrating;

  /// [profile] is what previous runs of the app left behind. The default is a
  /// user it has never seen, and reproduces the constants above exactly.
  CognitiveLoadIndex({LoadProfile profile = LoadProfile.fresh})
      : _profile = profile;

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

  /// The profile as it now stands, including everything this session has added
  /// to it. This is the value to persist.
  LoadProfile get profile => _profile;

  /// The user's own strain threshold.
  ///
  /// A user whose index habitually sits at 78 is not in strain at 70 - they
  /// are simply a person whose theta/alpha ratio runs high, and telling them
  /// so every waking minute trains them to ignore the app. Once there is
  /// enough of them on record the threshold moves to one standard deviation
  /// above their own mean, bounded so it stays a threshold.
  ///
  /// Below [kFramesBeforePersonalising] frames this is exactly [kStrainEnter],
  /// which is what makes every number in the README reproducible for a fresh
  /// user.
  double get strainEnter => _profile.indexFrames < kFramesBeforePersonalising
      ? kStrainEnter
      : (_profile.indexMean + kEnterSigma * _profile.indexSd)
          .clamp(kEnterFloor, kEnterCeiling);

  /// Always [kThresholdGap] below [strainEnter]. The latch depends on the gap,
  /// not on the absolute values, so personalising the position leaves the
  /// no-flicker behaviour untouched.
  double get strainExit => strainEnter - kThresholdGap;

  /// True once the thresholds have moved off the defaults.
  bool get isPersonalised =>
      _profile.indexFrames >= kFramesBeforePersonalising;

  /// Feed one analysis frame. Call once per [BandPowers] produced.
  void update(BandPowers p) {
    final r = math.log((p.theta + _eps) / (p.alpha + _eps));
    _lastR = r;

    if (_mu == null) {
      _baselineSamples.add(r);
      if (_baselineSamples.length >= _calibrationFrames) {
        _adoptBaseline(
            _baselineSamples.reduce((a, b) => a + b) / _baselineSamples.length);
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

    // The distribution learns from the smoothed value, because that is the one
    // the thresholds are compared against. Learning from the unsmoothed raw
    // would give the profile a wider spread than the state machine ever sees,
    // and personal thresholds derived from it would sit too high.
    _profile = _profile.withIndexFrame(_cli);

    _updateState();
  }

  /// Take [captured] - this session's 15 s mean log ratio - as the session
  /// baseline, and fold it into the long-run personal one.
  ///
  /// A capture that lands far from the personal baseline is not rejected, it
  /// is *pulled back* to the edge of the trust band. Rejecting it outright
  /// would leave a user with no baseline at all; taking it whole would let a
  /// session that began mid-strain define strain as normal. Pulling it back
  /// keeps the index reading high for someone who sat down already loaded,
  /// which is the honest answer.
  void _adoptBaseline(double captured) {
    final personal = _profile.baselineLogRatio;
    _mu = personal == null
        ? captured
        : captured.clamp(
            personal - kBaselineTrustBand, personal + kBaselineTrustBand);
    _profile = _profile.withSessionBaseline(captured);
  }

  void _updateState() {
    if (_state == LoadState.strain) {
      if (_cli < strainExit) {
        _state = LoadState.steady;
        _framesAboveEnter = 0;
      }
      return;
    }

    if (_cli >= strainEnter) {
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
  ///
  /// The profile deliberately survives this, and survives [reset] too: it
  /// describes the user, not the session. Throwing it away because someone
  /// tapped "recalibrate" would mean the app forgets them every time they ask
  /// it to look again.
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
