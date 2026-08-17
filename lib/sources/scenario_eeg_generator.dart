import 'dart:math' as math;

/// Synthetic EEG whose spectral content varies with a single "cognitive load"
/// scalar, so the Cognitive Load Index has something real to track.
///
/// The generator that shipped before this one emitted a constant 10 Hz sine.
/// That produces a flat index - correct, and useless as a demo. Here alpha is
/// suppressed and theta rises as load climbs, which is the actual
/// physiological signature the index is built to detect.
///
/// Amplitudes are chosen so that:
///
///   load 0.15 ->  alpha 630 uV^2, theta  71 uV^2  ->  CLI ~27
///   load 0.90 ->  alpha  85 uV^2, theta 493 uV^2  ->  CLI ~81
class ScenarioEEGGenerator {
  final double sampleRateHz;
  final math.Random _random;

  /// Where load is heading. Set directly for manual demo control.
  double loadTarget;

  /// Where load actually is - a first-order tracker toward [loadTarget], so
  /// transitions are smooth rather than a step discontinuity.
  double _load;

  /// Time constant of that tracker, in seconds.
  double tauSeconds;

  int _sampleIndex = 0;

  // Phase accumulators. Frequencies drift, so phase must be integrated
  // sample-by-sample; computing `2*pi*f(t)*t` directly would distort the
  // instantaneous frequency and smear the bands.
  double _phaseAlpha = 0, _phaseTheta = 0, _phaseBeta = 0, _phaseMains = 0;

  // Pink-noise filter state (Paul Kellet's approximation).
  double _p0 = 0, _p1 = 0, _p2 = 0;

  final double noiseRmsUv;
  final double mainsAmplitudeUv;

  ScenarioEEGGenerator({
    this.sampleRateHz = 256.0,
    double initialLoad = 0.15,
    this.tauSeconds = 4.0,
    this.noiseRmsUv = 12.0,
    this.mainsAmplitudeUv = 3.0,
    int? seed,
  })  : _load = initialLoad,
        loadTarget = initialLoad,
        _random = math.Random(seed);

  double get load => _load;

  double get elapsedSeconds => _sampleIndex / sampleRateHz;

  /// Jump the tracker straight to [value] with no easing. Used when resetting
  /// the scenario, not during a demo.
  void snapLoad(double value) {
    _load = value.clamp(0.0, 1.0);
    loadTarget = _load;
  }

  double nextSampleMicrovolts() {
    final dt = 1.0 / sampleRateHz;
    final t = elapsedSeconds;

    // First-order tracking toward the target.
    _load += (loadTarget - _load) * (dt / tauSeconds);
    _load = _load.clamp(0.0, 1.0);

    // Band amplitudes as a function of load.
    final aAlpha = 40.0 * (1 - 0.75 * _load); // suppressed under load
    final aTheta = 8.0 + 26.0 * _load; // frontal theta rises with load
    final aBeta = 6.0 + 8.0 * _load;

    // Slow frequency drift. This is why the index must integrate power over a
    // *band* rather than read a single bin - the peak wanders.
    final fAlpha = 10.0 + 0.6 * math.sin(2 * math.pi * t / 17.0);
    final fTheta = 6.0 + 0.4 * math.sin(2 * math.pi * t / 23.0);
    const fBeta = 18.0;

    _phaseAlpha += 2 * math.pi * fAlpha * dt;
    _phaseTheta += 2 * math.pi * fTheta * dt;
    _phaseBeta += 2 * math.pi * fBeta * dt;
    _phaseMains += 2 * math.pi * 60.0 * dt;

    // Slow amplitude "breathing", so band power is never perfectly steady.
    double breathe(double periodS, double phase) =>
        1 + 0.25 * math.sin(2 * math.pi * t / periodS + phase);

    final signal = aAlpha * breathe(11.0, 0.0) * math.sin(_phaseAlpha) +
        aTheta * breathe(13.0, 1.7) * math.sin(_phaseTheta) +
        aBeta * breathe(9.0, 3.1) * math.sin(_phaseBeta);

    _sampleIndex++;

    return signal +
        _pinkNoise() * noiseRmsUv +
        mainsAmplitudeUv * math.sin(_phaseMains);
  }

  /// Pink-ish (1/f) background, closer to real EEG than white noise.
  /// Returns roughly unit RMS.
  double _pinkNoise() {
    final w = _random.nextDouble() * 2 - 1;
    _p0 = 0.99765 * _p0 + w * 0.0990460;
    _p1 = 0.96300 * _p1 + w * 0.2965164;
    _p2 = 0.57000 * _p2 + w * 1.0526913;
    return (_p0 + _p1 + _p2 + w * 0.1848) / 3.5;
  }

  void reset() {
    _sampleIndex = 0;
    _phaseAlpha = _phaseTheta = _phaseBeta = _phaseMains = 0;
    _p0 = _p1 = _p2 = 0;
  }
}
