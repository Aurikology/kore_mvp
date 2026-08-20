import 'dart:collection';

import 'cognitive_load_index.dart';
import 'dsp_engine.dart';

/// What the predictor is able to say right now.
///
/// Split into five values rather than a bool because "no warning" has four
/// genuinely different meanings, and a demo that renders them all as a silent
/// green light is overclaiming three times out of four.
enum CrashForecastStatus {
  /// No personal baseline yet, so there is no index to extrapolate. The
  /// predictor says nothing at all during calibration - a forecast built on an
  /// index that is itself undefined would be theatre.
  uncalibrated,

  /// Calibrated, but less than [FocusCrashPredictor.kMinWindowSeconds] of
  /// trajectory behind it. A line through four points is not a trend.
  warmingUp,

  /// Enough history, and nothing is coming: the trajectory is flat, falling,
  /// reaches the threshold only beyond the horizon, or fits too poorly to be
  /// worth acting on.
  steady,

  /// The trajectory reaches the enter threshold inside the horizon, and the
  /// underlying theta/alpha ratio agrees that it is still climbing.
  crashLikely,

  /// Strain has already latched. There is nothing left to forecast; the app
  /// should be offering a reset, not a warning about one.
  alreadyStrained,
}

/// One forecast, produced fresh on every analysis frame.
class CrashForecast {
  final CrashForecastStatus status;

  /// Seconds until the fitted line reaches the enter threshold, or null when
  /// it never gets there. Deliberately still reported when it lands *outside*
  /// the horizon: "72 seconds away" and "not coming" are different answers,
  /// and collapsing them loses the more useful one.
  final double? secondsToCrossing;

  /// 0-1, and only meaningful for [CrashForecastStatus.steady] and
  /// [CrashForecastStatus.crashLikely] - the three states where nothing was
  /// computed report zero rather than a number they did not earn.
  final double confidence;

  /// Index points per second, from the fitted line.
  final double indexSlopePerSecond;

  /// Log theta/alpha units per second, from the same window. This is the
  /// unsmoothed driver behind the index.
  final double ratioSlopePerSecond;

  /// Fraction of the index's variance the fitted line explains (R^2).
  final double fit;

  const CrashForecast({
    required this.status,
    required this.secondsToCrossing,
    required this.confidence,
    required this.indexSlopePerSecond,
    required this.ratioSlopePerSecond,
    required this.fit,
  });

  static const CrashForecast silent = CrashForecast(
    status: CrashForecastStatus.uncalibrated,
    secondsToCrossing: null,
    confidence: 0,
    indexSlopePerSecond: 0,
    ratioSlopePerSecond: 0,
    fit: 0,
  );

  /// The one question the UI should ask. Kept as a getter so no caller has to
  /// remember which of the five statuses mean "act".
  bool get isWarning => status == CrashForecastStatus.crashLikely;

  @override
  String toString() => 'CrashForecast(${status.name}, '
      't=${secondsToCrossing?.toStringAsFixed(1) ?? '-'}s, '
      'conf=${confidence.toStringAsFixed(2)}, '
      'slope=${indexSlopePerSecond.toStringAsFixed(2)}/s)';
}

/// Forecasts a focus crash before the Cognitive Load Index arrives at one.
///
/// The index reports the present. This reports the near future: it fits a line
/// to the recent index trajectory and asks when that line reaches the enter
/// threshold. If the answer is inside [kHorizonSeconds], and the raw
/// theta/alpha ratio agrees that load is still climbing, it warns.
///
/// Two decisions carry the design.
///
/// **Extrapolate the index, corroborate with the ratio.** The index is what
/// the threshold is defined against, so it is the only honest thing to
/// extrapolate. But it is an EMA (tau ~= 2.1 s), and an EMA keeps rising for
/// seconds after its input has turned over - extrapolating it alone would fire
/// warnings straight through the top of a peak that had already passed. The
/// raw log ratio has no such lag, so its slope is used as a veto: a rising
/// index with a clearly falling ratio is smoothing momentum, not a crash.
///
/// **Everything is a straight line.** Not because load is linear, but because
/// a linear fit has one parameter to justify and an R^2 that says out loud how
/// well it describes the data. A higher-order fit over 12 s of a 4 Hz signal
/// would extrapolate noise with more confidence and less warning.
///
/// Pure and clock-free: it counts frames, so tests drive it directly without
/// fake time. Feed it once per completed analysis frame, in step with
/// [CognitiveLoadIndex.update].
class FocusCrashPredictor {
  // --- Tuning constants, at the top for the same reason as the index's. ---

  /// How far ahead a crossing counts as a warning. Long enough that a user can
  /// act before the crash - the reset protocol itself is 60 s - and short
  /// enough that a straight line is still a defensible model of the interval.
  static const double kHorizonSeconds = 20.0;

  /// Trajectory used for the fit. At 4 Hz this is 48 points.
  static const double kWindowSeconds = 12.0;

  /// Below this there is not enough trajectory to fit anything, and the
  /// predictor says [CrashForecastStatus.warmingUp] rather than guessing.
  static const double kMinWindowSeconds = 6.0;

  /// Index points per second below which a rise is not a trend. 0.1/s is a
  /// 2-point climb across the horizon - anything slower is noise wearing a
  /// slope.
  static const double kMinSlopePerSecond = 0.1;

  /// Deadband on the ratio slope, in log units per second. Set well above the
  /// standard error of a slope fitted through 12 s of raw ratio, so ordinary
  /// frame-to-frame noise cannot flip the sign either way. Only a *clearly*
  /// falling ratio vetoes; a flat one merely weakens the claim.
  static const double kRatioDeadband = 0.03;

  /// Confidence a warning must reach before it is published.
  static const double kMinConfidence = 0.35;

  /// Frames the criteria must hold before a warning latches, ~1 s at 4 Hz.
  ///
  /// One-sided on purpose: entering a warning is dwelled so a single noisy
  /// window cannot raise an alarm, but leaving one is immediate. A warning
  /// that outlives the risk it described is worse than one that never fired.
  static const int kConfirmFrames = 4;

  static const double _frameSeconds = 1.0 / DspConfig.framesPerSecond;

  final int _windowFrames = (kWindowSeconds * DspConfig.framesPerSecond).round();
  final int _minFrames = (kMinWindowSeconds * DspConfig.framesPerSecond).round();

  final ListQueue<_Point> _window = ListQueue<_Point>();

  int _frame = 0;
  int _framesConfirming = 0;
  CrashForecast _forecast = CrashForecast.silent;

  /// The current forecast. Re-derived on every [observe].
  CrashForecast get forecast => _forecast;

  /// Feed one analysis frame, immediately after [CognitiveLoadIndex.update].
  ///
  /// [deviation] is the raw log theta/alpha ratio measured against the personal
  /// baseline, i.e. [CognitiveLoadIndex.deviation]. [enterThreshold] is passed
  /// in rather than read from a constant so a personalised threshold forecasts
  /// against itself.
  ///
  /// [signalUsable] false is treated exactly as calibration is: the trajectory
  /// is dropped and nothing is published. It reports through
  /// [CrashForecast.silent] rather than earning a sixth status, because the
  /// answer to *why* the forecast went quiet belongs to the signal-quality
  /// getters - and every existing switch over these five statuses would
  /// otherwise have to grow an arm to restate what a quality flag already
  /// says.
  void observe({
    required double index,
    required double deviation,
    required LoadState state,
    double enterThreshold = CognitiveLoadIndex.kStrainEnter,
    bool signalUsable = true,
  }) {
    if (state == LoadState.calibrating || !signalUsable || !index.isFinite) {
      // Nothing collected during calibration is usable: the index is not
      // defined against a baseline yet, so a window spanning the moment the
      // baseline lands would fit a line to a discontinuity. A window spanning
      // a stretch of unusable signal has the same defect for the same reason,
      // and a forecast fitted across one warns about the electrode.
      _window.clear();
      _framesConfirming = 0;
      _forecast = CrashForecast.silent;
      return;
    }

    _window.addLast(_Point(
      t: _frame * _frameSeconds,
      index: index,
      deviation: deviation.isFinite ? deviation : 0.0,
    ));
    _frame++;
    while (_window.length > _windowFrames) {
      _window.removeFirst();
    }

    _forecast = _derive(state, enterThreshold);
  }

  CrashForecast _derive(LoadState state, double enterThreshold) {
    if (state == LoadState.strain) {
      // Keep filling the window - it has to be warm the moment strain clears -
      // but publish nothing.
      _framesConfirming = 0;
      return const CrashForecast(
        status: CrashForecastStatus.alreadyStrained,
        secondsToCrossing: null,
        confidence: 0,
        indexSlopePerSecond: 0,
        ratioSlopePerSecond: 0,
        fit: 0,
      );
    }

    if (_window.length < _minFrames) {
      _framesConfirming = 0;
      return const CrashForecast(
        status: CrashForecastStatus.warmingUp,
        secondsToCrossing: null,
        confidence: 0,
        indexSlopePerSecond: 0,
        ratioSlopePerSecond: 0,
        fit: 0,
      );
    }

    final points = _window.toList(growable: false);
    final indexFit = _leastSquares(
        points.length, (i) => points[i].t, (i) => points[i].index);
    final ratioFit = _leastSquares(
        points.length, (i) => points[i].t, (i) => points[i].deviation);

    final latest = points.last;
    final slope = indexFit.slope;

    // Where the line reaches the threshold, measured from the last observation
    // rather than from the fitted value at that instant: the user is where the
    // index says they are, and the fit only supplies the rate.
    final gap = enterThreshold - latest.index;
    final double? crossing =
        slope > 0 ? (gap <= 0 ? 0.0 : gap / slope) : null;

    CrashForecast steady(double confidence) {
      _framesConfirming = 0;
      return CrashForecast(
        status: CrashForecastStatus.steady,
        secondsToCrossing: crossing,
        confidence: confidence,
        indexSlopePerSecond: slope,
        ratioSlopePerSecond: ratioFit.slope,
        fit: indexFit.r2,
      );
    }

    if (slope < kMinSlopePerSecond) return steady(0);

    // The veto. A rising index whose driver is already falling is the EMA
    // coasting, and warning on it is how a predictor earns a reputation for
    // crying wolf.
    if (ratioFit.slope < -kRatioDeadband) return steady(0);

    if (crossing == null || crossing > kHorizonSeconds) return steady(0);

    // Corroboration from the ratio: full weight when it is clearly climbing,
    // most of the way when it is flat within the deadband. The sign is what is
    // trusted here, not the magnitude - the raw ratio is too noisy for its
    // slope to be read as a rate.
    final corroboration = ratioFit.slope > kRatioDeadband ? 1.0 : 0.6;

    // Nearer crossings are better claims: half the horizon away, the line has
    // to hold for twice as long to be right.
    final proximity = 1.0 - 0.5 * (crossing / kHorizonSeconds);

    final confidence =
        (indexFit.r2 * corroboration * proximity).clamp(0.0, 1.0);
    if (confidence < kMinConfidence) return steady(confidence);

    _framesConfirming++;
    if (_framesConfirming < kConfirmFrames) {
      return CrashForecast(
        status: CrashForecastStatus.steady,
        secondsToCrossing: crossing,
        confidence: confidence,
        indexSlopePerSecond: slope,
        ratioSlopePerSecond: ratioFit.slope,
        fit: indexFit.r2,
      );
    }

    return CrashForecast(
      status: CrashForecastStatus.crashLikely,
      secondsToCrossing: crossing,
      confidence: confidence,
      indexSlopePerSecond: slope,
      ratioSlopePerSecond: ratioFit.slope,
      fit: indexFit.r2,
    );
  }

  void reset() {
    _window.clear();
    _frame = 0;
    _framesConfirming = 0;
    _forecast = CrashForecast.silent;
  }
}

/// Ordinary least squares of y against t, with the fraction of variance the
/// line explains. Both come out of the same three sums, and every caller wants
/// the slope and the R^2 together - a slope without its goodness of fit is
/// exactly the number that produces confident nonsense.
({double slope, double r2}) _leastSquares(
  int n,
  double Function(int) t,
  double Function(int) y,
) {
  var meanT = 0.0, meanY = 0.0;
  for (var i = 0; i < n; i++) {
    meanT += t(i);
    meanY += y(i);
  }
  meanT /= n;
  meanY /= n;

  var stt = 0.0, sty = 0.0, syy = 0.0;
  for (var i = 0; i < n; i++) {
    final dt = t(i) - meanT;
    final dy = y(i) - meanY;
    stt += dt * dt;
    sty += dt * dy;
    syy += dy * dy;
  }

  if (stt <= 0) return (slope: 0.0, r2: 0.0);
  final slope = sty / stt;

  // A perfectly flat series has no variance to explain, so the line explains
  // all of it. That reads as r2 = 1 with slope 0, which is the truth and is
  // filtered out by the slope test anyway.
  final r2 = syy <= 1e-12 ? 1.0 : (sty * sty / (stt * syy)).clamp(0.0, 1.0);
  return (slope: slope, r2: r2);
}

class _Point {
  final double t;
  final double index;
  final double deviation;

  const _Point({required this.t, required this.index, required this.deviation});
}
