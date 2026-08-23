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

  /// Contact ramp per pad, in coupling per second. Non-zero models a headband
  /// working loose, which is the failure users actually hit: an electrode
  /// rarely goes from perfect to off in one step, and the interesting question
  /// is what the app does on the way down.
  ///
  /// Per pad rather than global because the failure worth rehearsing is the
  /// asymmetric one - one pad lifting while the others hold - which is exactly
  /// the case a single coupling scalar cannot represent.
  final Map<String, double> _padSlopes = {};

  /// Each pad's coupling, or null for a pad this device cannot measure.
  ///
  /// Nullable per pad so the "device measures some pads and not others" case
  /// is reachable in a test. Fabricating 1.0 for an unmeasurable pad is the
  /// lie [SignalQuality] exists to refuse.
  final Map<String, double?> _padContact = {};

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

  /// The pads this simulated patch has, as id -> user-facing label.
  ///
  /// Two by default, named positionally and in lay terms because that is the
  /// only naming the design docs ever put in approved copy ("press the left
  /// pad down until it reads"). Clinical 10-20 designators are ruled out: they
  /// read as medical instrumentation against a positioning that is explicitly
  /// not a medical device.
  ///
  /// This is a simulator convenience, **not a montage decision**. Nothing in
  /// the repo specifies an electrode count, a reference, or which pads feed
  /// the analysis; two is simply the smallest number that makes per-pad
  /// behaviour exercisable, and it is a constructor parameter so no montage
  /// gets committed to by accident.
  final Map<String, String> padLabels;

  SimulatedEegSource({
    ScenarioEEGGenerator? generator,
    this.autoTimeline = true,
    int Function()? elapsedMicros,
    Map<String, String>? padLabels,
  })  : generator = generator ?? ScenarioEEGGenerator(),
        padLabels = padLabels ??
            const {'left': 'Left pad', 'right': 'Right pad'},
        _injectedElapsedMicros = elapsedMicros {
    for (final id in this.padLabels.keys) {
      _padContact[id] = 1.0;
    }
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
    if (_padSlopes.isNotEmpty) {
      for (final entry in _padSlopes.entries) {
        final c = _padContact[entry.key];
        if (c == null) continue;
        _padContact[entry.key] =
            (c + entry.value * deltaSeconds).clamp(0.0, 1.0);
      }
      _syncGeneratorContact();
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
    return SignalQuality.fromElectrodes(
      electrodes: [
        for (final entry in padLabels.entries)
          ElectrodeContact(
            id: entry.key,
            label: entry.value,
            contact: _padContact[entry.key],
            impedanceKOhm: _impedanceFor(_padContact[entry.key]),
          ),
      ],
      droppedSamples: droppedSamples,
      measuredRateHz: effectiveSampleRateHz,
      nominalRateHz: generator.sampleRateHz,
    );
  }

  /// Impedance for a pad, or null when the pad cannot be measured at all.
  ///
  /// A pad with no coupling measurement has no impedance measurement either -
  /// deriving one would invent the very number the null is there to withhold.
  static double? _impedanceFor(double? contact) =>
      contact == null ? null : 5.0 + 195.0 * (1 - contact) * (1 - contact);

  /// Drive the signal model from the worst pad that can be measured.
  ///
  /// The generator mixes one coupling into one output sample, and that stays
  /// true: per-pad detail is something the *device* reports, not something the
  /// signal model needs to represent. Worst-wins here keeps the artifact the
  /// user sees consistent with the verdict they are told.
  ///
  /// Pads that cannot be measured leave the signal alone. An unmeasurable pad
  /// is not a detached one.
  void _syncGeneratorContact() {
    double? worst;
    for (final c in _padContact.values) {
      if (c == null) continue;
      if (worst == null || c < worst) worst = c;
    }
    generator.contact = worst ?? 1.0;
  }

  /// Emits on [qualityUpdates] only when the verdict changes, not on every
  /// 16 ms block: a consumer subscribing to a stream called "updates" wants
  /// the transitions, and the current value is always on [quality].
  void _publishQuality(SignalQuality next) {
    final changed = next.level != _quality.level ||
        !_sameFaults(next.faults, _quality.faults) ||
        !_samePadStates(next, _quality);
    _quality = next;
    if (changed && !_qualityController.isClosed) {
      _qualityController.add(next);
    }
  }

  static bool _sameFaults(Set<SignalFault> a, Set<SignalFault> b) =>
      a.length == b.length && a.containsAll(b);

  /// Whether every pad still reads in the same band as it did.
  ///
  /// Without this the stream is deaf to the transition that matters most once
  /// pads are independent: a second pad sliding out of `good` while a first is
  /// already detached moves neither the aggregate level nor the fault set, so
  /// a per-pad contact view subscribed to `qualityUpdates` would never
  /// repaint and the user would re-seat one pad and stop.
  ///
  /// Banded state rather than raw coupling on purpose - comparing raw values
  /// would emit on every tick of a ramp and turn a stream of transitions into
  /// a stream of samples.
  static bool _samePadStates(SignalQuality a, SignalQuality b) {
    if (a.electrodes.length != b.electrodes.length) return false;
    for (var i = 0; i < a.electrodes.length; i++) {
      if (a.electrodes[i].id != b.electrodes[i].id) return false;
      if (a.electrodes[i].state != b.electrodes[i].state) return false;
    }
    return true;
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

  // --- Fault injection ----------------------------------------------------
  //
  // Each of these exists so the quality path can be demonstrated and
  // regression-tested with no hardware, and together they are what makes a BLE
  // source a drop-in: by the time one exists, everything downstream has
  // already been run against each of these failures.

  /// Seat every pad at a fixed coupling, 0 (off the head) to 1 (perfect).
  ///
  /// Whole-patch rather than per-pad, so the scripted demo and every test
  /// written before pads existed keep meaning what they meant.
  void setContact(double contact) {
    _padSlopes.clear();
    for (final id in padLabels.keys) {
      _padContact[id] = contact.clamp(0.0, 1.0);
    }
    _syncGeneratorContact();
    _publishQuality(_report(0));
  }

  /// Seat one pad, leaving the others alone.
  ///
  /// Pass null for [contact] to model a pad this device cannot measure - which
  /// is not the same as a pad that is off, and must not read as one.
  void setPadContact(String id, double? contact) {
    _requirePad(id);
    _padSlopes.remove(id);
    _padContact[id] = contact?.clamp(0.0, 1.0);
    _syncGeneratorContact();
    _publishQuality(_report(0));
  }

  /// A headband working loose: coupling falls steadily on every pad until
  /// something stops it. [perSecond] is coupling lost per second, so the
  /// default takes a perfect electrode to unusable in about eight seconds.
  void degradeContact({double perSecond = 0.08}) {
    for (final id in padLabels.keys) {
      _padSlopes[id] = -perSecond.abs();
    }
  }

  /// One pad working loose while the others hold.
  ///
  /// The asymmetric failure is the one worth rehearsing: it is what the
  /// pairing screen has to name, and what a single coupling scalar could not
  /// express.
  void degradePad(String id, {double perSecond = 0.08}) {
    _requirePad(id);
    _padSlopes[id] = -perSecond.abs();
  }

  /// Every pad comes off. Not silence - see [ScenarioEEGGenerator.contact].
  void detachElectrode() => setContact(0.0);

  /// One pad comes off.
  void detachPad(String id) => setPadContact(id, 0.0);

  /// Back on the head and seated properly, every pad.
  void restoreContact() => setContact(1.0);

  void _requirePad(String id) {
    if (!padLabels.containsKey(id)) {
      throw ArgumentError.value(
          id, 'id', 'no such pad; this patch has ${padLabels.keys.join(", ")}');
    }
  }

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
