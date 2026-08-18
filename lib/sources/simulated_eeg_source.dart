import 'dart:async';

import '../services/eeg_data_stream.dart';
import 'eeg_source.dart';
import 'scenario_eeg_generator.dart';

/// Drives [ScenarioEEGGenerator] on a wall clock and emits sample blocks.
///
/// The timer fires every 16 ms and generates however many samples that much
/// elapsed time is worth, carrying the fractional remainder forward. The
/// previous implementation used `Timer.periodic(1000 ~/ 256)` - integer
/// division, so 3 ms, so ~333 Hz while the UI claimed 256 Hz. Windows' timer
/// resolution is ~15.6 ms anyway, so a 3.9 ms timer was never going to be
/// honoured; accumulating against the real clock gives an exactly-256-Hz
/// average and is honest about how it gets there.
class SimulatedEegSource implements EegSource {
  static const Duration _tick = Duration(milliseconds: 16);

  final ScenarioEEGGenerator generator;

  final _controller = StreamController<List<EEGSample>>.broadcast();
  Timer? _timer;
  Stopwatch? _clock;
  int _lastElapsedMicros = 0;
  double _sampleCarry = 0;

  /// When true the load follows the scripted demo timeline. Any manual
  /// control switches it off - during a live demo you want the presenter
  /// driving, not a wall clock.
  bool autoTimeline;

  SimulatedEegSource({
    ScenarioEEGGenerator? generator,
    this.autoTimeline = true,
  }) : generator = generator ?? ScenarioEEGGenerator();

  @override
  Stream<List<EEGSample>> get sampleBlocks => _controller.stream;

  @override
  int get samplingRateHz => generator.sampleRateHz.round();

  @override
  String get label => 'Simulated signal';

  double get elapsedSeconds => generator.elapsedSeconds;

  @override
  Future<void> start() async {
    if (_timer != null) return;
    _clock = Stopwatch()..start();
    _lastElapsedMicros = 0;
    _timer = Timer.periodic(_tick, (_) => _pump());
  }

  void _pump() {
    final now = _clock!.elapsedMicroseconds;
    final deltaSeconds = (now - _lastElapsedMicros) / 1e6;
    _lastElapsedMicros = now;

    final exact = deltaSeconds * generator.sampleRateHz + _sampleCarry;
    final count = exact.floor();
    _sampleCarry = exact - count;

    if (count <= 0) return;
    // Guard against a debugger pause or a suspended laptop producing a
    // pathological catch-up burst.
    final n = count.clamp(0, 2048);

    if (autoTimeline) _applyTimeline(generator.elapsedSeconds);

    final ts = DateTime.now().millisecondsSinceEpoch;
    final block = List<EEGSample>.generate(
      n,
      (_) => EEGSample(
        timestamp: ts,
        channels: [generator.nextSampleMicrovolts()],
      ),
    );

    if (!_controller.isClosed) _controller.add(block);
  }

  /// Scripted demo arc.
  ///
  /// Calibration needs ~19 s (2 s to fill the analysis window, then 15 s of
  /// baseline capture), so the calm stretch runs to 30 s. That leaves a clear
  /// beat where the index sits at its resting value before it starts to
  /// climb - without it the number is already rising the moment it appears,
  /// and the viewer never sees what "steady" looks like.
  void _applyTimeline(double t) {
    const calmUntil = 30.0;
    const rampSeconds = 30.0;

    if (t < calmUntil) {
      generator.loadTarget = 0.15;
    } else if (t < calmUntil + rampSeconds) {
      generator.loadTarget = 0.15 + 0.75 * ((t - calmUntil) / rampSeconds);
    } else {
      generator.loadTarget = 0.90;
    }
  }

  /// Manual demo control. Takes the timeline out of the loop.
  void setLoadTarget(double target, {double? tauSeconds}) {
    autoTimeline = false;
    generator.loadTarget = target.clamp(0.0, 1.0);
    if (tauSeconds != null) generator.tauSeconds = tauSeconds;
  }

  /// Called when a reset protocol completes: load falls away over the
  /// following seconds, so recovery is visible rather than instantaneous.
  void applyResetRecovery() => setLoadTarget(0.15, tauSeconds: 12.0);

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _clock?.stop();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _controller.close();
  }
}
