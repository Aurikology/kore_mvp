import 'dart:async';

import '../services/eeg_data_stream.dart';
import '../services/signal_quality.dart';
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
///
/// It also injects the faults a real electrode produces - degrading contact,
/// a detached electrode, lost blocks, a drifting crystal - because otherwise
/// the handling for them gets written for the first time with a radio on the
/// desk and a deadline. See `docs/signal-quality.md`.
class SimulatedEegSource implements EegSource {
  static const Duration _tick = Duration(milliseconds: 16);

  final ScenarioEEGGenerator generator;

  final _controller = StreamController<SampleBlock>.broadcast();
  final _qualityController = StreamController<SignalQuality>.broadcast();
  Timer? _timer;
  Stopwatch? _clock;
  int _lastElapsedMicros = 0;
  double _sampleCarry = 0;

  /// Where the device thinks it is in its own stream. Advanced by dropped
  /// samples as well as delivered ones - which is the entire point of it.
  int _deviceSampleIndex = 0;

  /// Samples still to be swallowed before delivery resumes.
  int _dropsRemaining = 0;

  /// Contact ramp, in coupling per second. Non-zero models a headband working
  /// loose, which is the failure users actually hit: an electrode rarely goes
  /// from perfect to off in one step, and the interesting question is what the
  /// app does on the way down.
  double _contactSlopePerSecond = 0;

  /// Fractional clock error, e.g. 0.004 for a crystal running 0.4% fast.
  double _rateErrorFraction = 0;

  SignalQuality _quality = const SignalQuality.pristine(256.0);

  /// Microseconds since [start], as a function so it can be replaced.
  ///
  /// The default reads a real [Stopwatch], which is the whole point of this
  /// class - see the note above about the 16 ms timer. It also means fake
  /// time cannot drive it: under `flutter test` timers are faked but a
  /// Stopwatch is not, so pumping produces no samples and the index never
  /// calibrates. Injecting the clock is what makes the full detect -> reset
  /// -> confirm path testable.
  final int Function()? _injectedElapsedMicros;

  /// When true the load follows the scripted demo timeline. Any manual
  /// control switches it off - during a live demo you want the presenter
  /// driving, not a wall clock.
  bool autoTimeline;

  SimulatedEegSource({
    ScenarioEEGGenerator? generator,
    this.autoTimeline = true,
    int Function()? elapsedMicros,
  })  : generator = generator ?? ScenarioEEGGenerator(),
        _injectedElapsedMicros = elapsedMicros {
    _quality = _report(0);
  }

  int get _elapsedMicros =>
      _injectedElapsedMicros?.call() ?? _clock?.elapsedMicroseconds ?? 0;

  @override
  Stream<SampleBlock> get sampleBlocks => _controller.stream;

  @override
  Stream<SignalQuality> get qualityUpdates => _qualityController.stream;

  @override
  SignalQuality get quality => _quality;

  @override
  double get effectiveSampleRateHz =>
      generator.sampleRateHz * (1 + _rateErrorFraction);

  @override
  int get samplingRateHz => generator.sampleRateHz.round();

  @override
  String get label => 'Simulated signal';

  double get elapsedSeconds => generator.elapsedSeconds;

  @override
  Future<void> start() async {
    if (_timer != null) return;
    if (_injectedElapsedMicros == null) _clock = Stopwatch()..start();
    _lastElapsedMicros = 0;
    _timer = Timer.periodic(_tick, (_) => _pump());
  }

  void _pump() {
    final now = _elapsedMicros;
    final deltaSeconds = (now - _lastElapsedMicros) / 1e6;
    _lastElapsedMicros = now;

    // A crystal running fast delivers more samples per second of host time,
    // and the count is where that has to show up. Reporting a drifted rate
    // while still emitting exactly 256 Hz would be a simulator that agrees
    // with itself and with nothing else.
    final exact = deltaSeconds * effectiveSampleRateHz + _sampleCarry;
    final count = exact.floor();
    _sampleCarry = exact - count;

    if (count <= 0) return;
    // Guard against a debugger pause or a suspended laptop producing a
    // pathological catch-up burst.
    final n = count.clamp(0, 2048);

    if (autoTimeline) _applyTimeline(generator.elapsedSeconds);
    if (_contactSlopePerSecond != 0) {
      generator.contact =
          generator.contact + _contactSlopePerSecond * deltaSeconds;
    }

    // Dropped samples are generated and thrown away rather than skipped. The
    // device did take them; the radio is what lost them, and the phase of
    // everything downstream has to move on as though it had.
    final dropped = n < _dropsRemaining ? n : _dropsRemaining;
    for (var i = 0; i < dropped; i++) {
      generator.nextSampleMicrovolts();
    }
    _dropsRemaining -= dropped;
    _deviceSampleIndex += dropped;

    final delivered = n - dropped;
    if (delivered <= 0) {
      _publishQuality(_report(dropped));
      return;
    }

    final firstIndex = _deviceSampleIndex;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final samples = List<EEGSample>.generate(
      delivered,
      (_) => EEGSample(
        timestamp: ts,
        channels: [generator.nextSampleMicrovolts()],
      ),
    );
    _deviceSampleIndex += delivered;

    _publishQuality(_report(dropped));

    if (!_controller.isClosed) {
      _controller.add(SampleBlock(
        samples: samples,
        firstSampleIndex: firstIndex,
        quality: _quality,
      ));
    }
  }

  /// The report that goes out with the block just assembled.
  ///
  /// A real front end measures impedance and derives coupling from it; here it
  /// runs the other way, which is exactly why impedance is never allowed to
  /// gate anything - see [SignalQuality.impedanceKOhm].
  SignalQuality _report(int droppedSamples) {
    final c = generator.contact;
    return SignalQuality(
      contact: c,
      impedanceKOhm: 5.0 + 195.0 * (1 - c) * (1 - c),
      droppedSamples: droppedSamples,
      measuredRateHz: effectiveSampleRateHz,
      nominalRateHz: generator.sampleRateHz,
    );
  }

  /// Emits on [qualityUpdates] only when the verdict changes, not on every
  /// 16 ms block: a consumer subscribing to a stream called "updates" wants
  /// the transitions, and the current value is always on [quality].
  void _publishQuality(SignalQuality next) {
    final changed = next.level != _quality.level ||
        !_sameFaults(next.faults, _quality.faults);
    _quality = next;
    if (changed && !_qualityController.isClosed) {
      _qualityController.add(next);
    }
  }

  static bool _sameFaults(Set<SignalFault> a, Set<SignalFault> b) =>
      a.length == b.length && a.containsAll(b);

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

  // --- Fault injection ----------------------------------------------------
  //
  // Each of these exists so the quality path can be demonstrated and
  // regression-tested with no hardware, and together they are what makes a BLE
  // source a drop-in: by the time one exists, everything downstream has
  // already been run against each of these failures.

  /// Seat the electrode at a fixed coupling, 0 (off the head) to 1 (perfect).
  void setContact(double contact) {
    _contactSlopePerSecond = 0;
    generator.contact = contact;
    _publishQuality(_report(0));
  }

  /// A headband working loose: coupling falls steadily until something stops
  /// it. [perSecond] is coupling lost per second, so the default takes a
  /// perfect electrode to unusable in about eight seconds.
  void degradeContact({double perSecond = 0.08}) {
    _contactSlopePerSecond = -perSecond.abs();
  }

  /// The electrode comes off. Not silence - see [ScenarioEEGGenerator.contact].
  void detachElectrode() => setContact(0.0);

  /// Back on the head and seated properly.
  void restoreContact() => setContact(1.0);

  /// Lose the next [count] samples the way a missed BLE notification does: the
  /// device still produces them, the app never sees them, and the sample index
  /// jumps by exactly the number that went missing.
  void dropSamples(int count) => _dropsRemaining += count.clamp(0, 1 << 20);

  /// Run the device's clock off nominal by [fraction], e.g. 0.004 for 0.4%
  /// fast. Negative runs slow.
  void setSampleRateError(double fraction) {
    _rateErrorFraction = fraction;
    _publishQuality(_report(0));
  }

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
    _qualityController.close();
  }
}
