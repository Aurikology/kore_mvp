import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../dsp/cognitive_load_index.dart';
import '../dsp/dsp_engine.dart';
import '../dsp/dsp_engine_factory.dart';
import '../dsp/focus_crash_predictor.dart';
import '../dsp/load_profile.dart';
import '../services/eeg_data_stream.dart';
import '../services/history_store.dart';
import '../services/signal_quality.dart';
import '../sources/demo_controls.dart';
import '../sources/eeg_source.dart';
import '../sources/simulated_eeg_source.dart';
import '../sources/source_link.dart';
import 'kore_history.dart';
import 'reset_record.dart';
import 'signal_quality_gate.dart';

/// Owns the live pipeline: source -> DSP engine -> Cognitive Load Index.
///
/// Notifies listeners **once per completed analysis frame (4 Hz)**, not once
/// per sample. The previous screen called setState() on every sample at
/// ~333 Hz, rebuilding the whole tree each time; here the 256 Hz acquisition
/// is fully decoupled from the repaint rate.
class KoreSession extends ChangeNotifier {
  static const int historyLength = 480; // 120 s at 4 Hz
  static const Duration resetDuration = Duration(seconds: 60);

  /// The seam, held as the seam.
  ///
  /// This was `SimulatedEegSource` until the session needed to be honest about
  /// what it depends on. Everything simulator-specific now goes through
  /// [DemoControls], which a real source does not offer - so a BLE source
  /// drops in here without a single change below this line.
  final EegSource source;
  final DspEngine engine;
  final CognitiveLoadIndex index = CognitiveLoadIndex();
  final FocusCrashPredictor predictor = FocusCrashPredictor();

  /// Null means history lives in memory for this run only. The real store is
  /// wired at the composition root (`main`), which keeps widget tests from
  /// writing to the user's AppData just by pumping the app.
  final HistoryStore? store;

  /// Widens the source's per-block quality report to the analysis window the
  /// index actually consumes. Everything that decides whether to believe a
  /// reading asks this, and nothing asks the source directly.
  final SignalQualityGate signalGate = SignalQualityGate();

  /// The sparkline's window. Null entries are stretches the app was not
  /// measuring through - see [resume].
  final ListQueue<double?> _history = ListQueue<double?>();

  StreamSubscription<SampleBlock>? _subscription;
  StreamSubscription<SignalQuality>? _qualitySubscription;
  StreamSubscription<SourceLink>? _linkSubscription;

  /// When the app went into the background, or null while it is in front.
  DateTime? _pausedAt;

  bool _resetActive = false;
  int _resetSecondsRemaining = 0;
  Timer? _resetTimer;

  ResetHistory _resetHistory = ResetHistory.empty;
  DailyLoadLog _days = DailyLoadLog.empty;
  _PendingReset? _pending;
  DateTime? _startedAt;
  double _loadBefore = 0;

  /// Whether the signal stayed believable for the whole of the reset now
  /// running. One unusable frame anywhere in the 60 s is enough to make the
  /// before/after pair arithmetic over noise.
  bool _resetSignalClean = true;

  // Today's rollup, accumulated over calibrated frames and folded into [_days]
  // whenever the session writes. Held separately rather than recomputed from
  // [_history] because that queue is 120 s long and a day is not.
  int _dayFrames = 0;
  double _daySum = 0;
  double _dayPeak = 0;

  /// Wall clock, injectable for the same reason the source's is.
  ///
  /// Only the suspend/resume gap reads it. That gap is measured in real
  /// minutes, and a test cannot wait out four of them - everything else here
  /// that needs the date already takes it as a parameter.
  final DateTime Function() now;

  KoreSession({
    EegSource? source,
    DspEngine? engine,
    this.store,
    DateTime Function()? now,
  })  : source = source ?? SimulatedEegSource(),
        engine = engine ?? createDspEngine(),
        now = now ?? DateTime.now;

  // --- Read model for the UI ---------------------------------------------

  double get cognitiveLoad => index.value;

  LoadState get loadState => index.state;

  bool get isCalibrated => index.isCalibrated;

  /// The near-future read on the same signal: is the index about to cross into
  /// strain? Carries its own status and confidence, so the UI can distinguish
  /// "nothing coming" from "cannot say yet".
  CrashForecast get crashForecast => predictor.forecast;

  /// The one bit the dashboard needs. A forecast is only actionable when it is
  /// a warning; every other status is a reason to stay quiet.
  bool get crashWarning => predictor.forecast.isWarning;

  /// The threshold in force *now*, which is not the published constant once a
  /// profile has personalised it. Anything that draws the threshold has to read
  /// it from here: a gauge tick at 70 for a user whose threshold has moved to
  /// 78 marks the wrong place on the dial and contradicts the state chip
  /// beside it.
  double get strainEnter => index.strainEnter;

  /// Whether [strainEnter] is this user's own number or still the default, so
  /// the UI can say which it is showing rather than implying the number was
  /// earned.
  bool get thresholdsPersonalised => index.isPersonalised;

  double get calibrationProgress => index.calibrationProgress;

  int get calibrationSecondsRemaining =>
      index.secondsRemainingInCalibration.ceil();

  // --- Signal quality -----------------------------------------------------
  //
  // Load state answers "how loaded is this person". These answer "can we see
  // them at all", and they are orthogonal: a detached electrode produces
  // theta-up and alpha-down, which is the cognitive-load signature exactly, so
  // a bad reading here is a *plausible* one rather than an obviously broken
  // one. Anything rendering [cognitiveLoad], [loadState] or [crashForecast]
  // has to consult [isReadingTrustworthy] first. See `docs/signal-quality.md`.

  /// The source's live measurements: coupling, impedance, dropped samples,
  /// measured rate. Re-read on every frame.
  ///
  /// Read this for the numbers. Read [signalQualityLevel] and [signalFaults]
  /// for the verdict - they account for the 2 s analysis window, which the
  /// source knows nothing about, and for a couple of seconds after a fault
  /// clears they will deliberately disagree with `signalQuality.level`.
  SignalQuality get signalQuality => signalGate.quality;

  /// The one-word verdict - good, degraded, or unusable. This is the one to
  /// render.
  SignalQualityLevel get signalQualityLevel => signalGate.level;

  /// Whether [cognitiveLoad], [loadState] and [crashForecast] describe the
  /// user right now.
  ///
  /// False means the signal is not worth believing. [cognitiveLoad] then holds
  /// the last value measured from a signal that was, so a gauge has something
  /// to keep painting - but it is stale, and presenting it as current is the
  /// failure this whole path exists to prevent.
  bool get isReadingTrustworthy => signalGate.isUsable;

  /// What is wrong, when something is, so the UI can say *which* problem the
  /// user has: poor contact and a dropout have different fixes. Empty when
  /// nothing is wrong.
  Set<SignalFault> get signalFaults => signalGate.faults;

  /// Usable, but on the way to not being. True when the reading still
  /// publishes and the user should be told to fix something anyway.
  bool get signalDegraded =>
      signalQualityLevel == SignalQualityLevel.degraded;

  /// True while the baseline capture is standing still because the signal is
  /// not clean enough to define one from.
  ///
  /// Worth its own getter because the symptom without the explanation is a
  /// countdown that has stopped counting, and users read that as a crash.
  bool get calibrationStalled => !isCalibrated && !signalGate.isBaselineGrade;

  /// Electrode-skin coupling, 0 to 1, or null when the source cannot measure
  /// it. Null is not a fault - it means "not measured", and must never be
  /// rendered as good contact.
  double? get electrodeContact => signalQuality.contact;

  /// Per-pad contact, when the source reports it. Empty when it does not -
  /// which means the device did not break contact down, not that its pads are
  /// fine. Anything naming a pad has to check this rather than index into it.
  ///
  /// This is what the pairing screen's contact check reads, and what lets the
  /// dashboard say *which* pad to press instead of "contact is poor", which
  /// is not an instruction anyone can follow.
  List<ElectrodeContact> get electrodes => signalQuality.electrodes;

  /// The pads the user could do something about, worst first. Pads that
  /// cannot be measured are excluded: there is no instruction to give for a
  /// pad whose state is unknown.
  List<ElectrodeContact> get electrodesNeedingAttention =>
      signalQuality.electrodesNeedingAttention;

  /// Whether every measurable pad is seated well enough to calibrate against.
  ///
  /// The pairing screen's Continue button is gated on this. Note it is not
  /// `isReadingTrustworthy`: publishing a reading and capturing the baseline
  /// every later reading is measured against have different bars.
  bool get allPadsSeated =>
      signalQuality.hasPerElectrodeContact &&
      signalQuality.electrodesNeedingAttention.isEmpty;

  /// The rate the device is actually sampling at, against the 256 Hz the DSP
  /// was built for.
  double get measuredSampleRateHz => signalQuality.measuredRateHz;

  /// Oldest-to-newest index history, for the sparkline. Null where nothing was
  /// measured.
  List<double?> get history => List.unmodifiable(_history);

  bool get resetActive => _resetActive;

  int get resetSecondsRemaining => _resetSecondsRemaining;

  double get resetProgress =>
      _resetActive ? 1 - (_resetSecondsRemaining / resetDuration.inSeconds) : 0;

  ResetHistory get resetHistory => _resetHistory;

  /// The longitudinal record, for anything that wants a trend rather than a
  /// reading. Excludes whatever today's session has measured since the last
  /// write; [flushState] brings it up to date.
  DailyLoadLog get dailyLoad => _days;

  /// The user's persistent baseline and thresholds, as this session has left
  /// them.
  LoadProfile get loadProfile => index.profile;

  /// A finished reset is waiting to be written. The check-in is only offered
  /// for a protocol that actually ran to the end - asking "did that help?"
  /// after a four-second abort would collect noise and call it a metric.
  bool get awaitingCheckIn => _pending?.completed ?? false;

  bool get hasUncommittedReset => _pending != null;

  /// Index points the pending reset moved, positive when the load fell.
  double get pendingDrop {
    final p = _pending;
    return p == null ? 0 : p.loadBefore - p.loadAfter;
  }

  String get backendLabel => engine.backendLabel;

  String get sourceLabel => source.label;

  /// Where the link to the device is, as one value.
  ///
  /// The dashboard could previously say "your load is 0" but not "the patch is
  /// not connected"; [sourceLabel] is a fixed string and says nothing about
  /// whether anything is on the other end of it.
  SourceLink get link => source.link;

  SourceLinkState get linkState => source.link.state;

  /// What is on the other end, once something is. Null while scanning.
  PatchIdentity? get patch => source.link.patch;

  /// Whether samples are arriving right now. Distinct from [isReadingTrustworthy]:
  /// this is about the radio, that is about the electrode, and a session can
  /// fail either independently.
  bool get isLinkLive => source.link.isLive;

  /// The simulator's levers, or null when there is nothing to simulate.
  /// The demo panel is built off this and disappears without it.
  DemoControls? get demo => source.demo;

  bool get hasDemoControls => source.demo != null;

  bool get followingTimeline => source.demo?.followingTimeline ?? false;

  /// Simulated load level, surfaced only for the demo control row.
  double get simulatedLoad => source.demo?.load ?? 0;

  // --- Lifecycle ----------------------------------------------------------

  /// Idempotent, and that is not defensive coding - it is the first-run flow.
  /// The pairing screen starts the session so its contact check is live, and
  /// the dashboard starts the same session again when it mounts. A second call
  /// must not double-subscribe to the block stream, which would push every
  /// sample through the engine twice.
  Future<void> start() async {
    if (_subscription != null) return;

    // Load first so the dashboard shows the real streak on the first frame
    // rather than flashing a zero and correcting itself - and, since this
    // completes before a single sample arrives, so the baseline capture that
    // is about to start is checked against the profile it should be.
    final loaded = await store?.loadDocument();
    if (loaded != null) {
      _resetHistory = loaded.resets;
      _days = loaded.days;
      index.adoptProfile(loaded.profile);
      notifyListeners();
    }

    _subscription = source.sampleBlocks.listen(_onBlock);
    // Separately from the blocks, because the failure that matters most sends
    // no blocks at all: a link that has dropped delivers nothing, and a
    // consumer that only learned quality from arriving samples would hold a
    // stale "good" for as long as the silence lasted.
    _qualitySubscription = source.qualityUpdates.listen(_onQuality);
    // And separately again from quality, because the two fail independently:
    // a seated electrode on a radio that has dropped reports perfect contact
    // right up until it reports nothing at all.
    _linkSubscription = source.linkUpdates.listen(_onLink);
    await source.start();
  }

  /// The app has gone into the background.
  ///
  /// `start()` assumed a stream that never stops, which is true of a desktop
  /// window and false of a phone: the OS suspends the app constantly, and it
  /// does not ask. Stopping the source is the honest response - a session
  /// whose timers have been throttled to nothing is not measuring, and should
  /// not be holding a subscription open pretending otherwise.
  Future<void> pause() async {
    if (_pausedAt != null) return;
    _pausedAt = now();
    await source.stop();
    notifyListeners();
  }

  /// The app is back.
  ///
  /// The interesting case is not restarting the source, it is what happens to
  /// the gap. The index is a 2 s Hann-windowed analysis over a ring buffer
  /// written by position, so samples from either side of a suspension sit
  /// adjacent in that ring and the window spanning them reads a discontinuity
  /// as broadband power in theta and alpha at once. Nothing about that is
  /// visible downstream: the number moves, the predictor sees a trajectory,
  /// and neither is describing the user.
  ///
  /// So a gap longer than one analysis window is refused rather than spliced.
  /// The engine's ring and filters are cleared, the predictor's trajectory
  /// with them, the gate is told to require a full clean window before
  /// believing a frame again, and the sparkline gets a hole rather than a line
  /// drawn across minutes nobody measured.
  ///
  /// A gap *shorter* than one window is left alone deliberately. Every one of
  /// those costs a two-second settle, and a phone that flickers in and out of
  /// the background for half a second at a time would spend its life settling
  /// and never publish anything.
  Future<void> resume() async {
    final since = _pausedAt;
    _pausedAt = null;
    if (since == null) return;

    final gap = now().difference(since);
    if (gap >= _minimumGap) {
      engine.reset();
      predictor.reset();
      // Not `dropout`: nothing was dropped by the radio, and the fix the user
      // would be offered for one ("move closer to the device") is nonsense
      // here. `settling` says what is true - the reading is being taken again
      // - and asks nothing of anybody.
      signalGate.contaminate(const {SignalFault.settling});

      // A hole, not a truncation. The readings before the suspension were
      // real and stay on the chart; what must not happen is a straight line
      // joining them to the ones after, which reads as a measurement of calm
      // across exactly the minutes there was no measurement at all.
      if (_history.isNotEmpty && _history.last != null) {
        _history.addLast(null);
        while (_history.length > historyLength) {
          _history.removeFirst();
        }
      }
    }

    await source.start();
    notifyListeners();
  }

  /// One analysis window. Below this a gap cannot span a frame, so there is
  /// nothing to refuse.
  static final Duration _minimumGap = Duration(
      milliseconds:
          (DspConfig.windowSize / DspConfig.sampleRateHz * 1000).round());

  /// Drop the link without tearing the session down. The pairing screen's
  /// Cancel; [start] picks it back up.
  ///
  /// Goes through the session rather than having the screen call
  /// `session.source.stop()` itself, so the read model stays the only thing
  /// the UI talks to.
  Future<void> disconnect() => source.stop();

  void _onLink(SourceLink link) => notifyListeners();

  void _onQuality(SignalQuality quality) {
    signalGate.observeQuality(quality);
    if (_resetActive && !signalGate.isUsable) _resetSignalClean = false;
    notifyListeners();
  }

  void _onBlock(SampleBlock block) {
    if (block.isEmpty) return;

    signalGate.observeBlock(block);

    // The engine is fed whatever arrives, always. Its filters have to stay
    // warm and its window has to keep flushing through a bad patch, otherwise
    // recovery would cost a fresh settling transient on top of the fault.
    // Refusing to *believe* the frames is a separate decision from refusing to
    // compute them.
    engine.pushBlock([
      for (final s in block.samples)
        if (s.channels.isNotEmpty) s.channels[0],
    ]);

    final frame = engine.takeFrame();
    if (frame == null) return; // no new analysis window yet

    final quality = signalGate.quality;
    final usable = quality.isUsable;
    if (_resetActive && !usable) _resetSignalClean = false;

    final wasCalibrated = index.isCalibrated;

    index.update(frame, quality: quality.level);
    predictor.observe(
      index: index.value,
      deviation: index.deviation,
      state: index.state,
      // The user's own threshold, not the default: forecasting a crossing of
      // a line the state machine is not using would warn about nothing.
      enterThreshold: index.strainEnter,
      signalUsable: usable,
    );

    if (index.isCalibrated && usable) {
      // Nothing measured through an unusable signal enters the record. The
      // sparkline simply stops advancing rather than drawing a held value: a
      // flat run in a trend reads as a measurement of calm, and this is the
      // opposite of one.
      _history.addLast(index.value);
      while (_history.length > historyLength) {
        _history.removeFirst();
      }

      // [wasCalibrated], not [index.isCalibrated]: the frame that *completes*
      // the capture has not produced an index yet, and folding its zero into
      // the day's mean would be recording a reading that never happened.
      if (wasCalibrated) {
        _dayFrames++;
        _daySum += index.value;
        if (index.value > _dayPeak) _dayPeak = index.value;
      }
    }

    // Write the moment the baseline lands. Most sessions never take a reset,
    // and those are exactly the sessions the profile has to learn from - if
    // the only write were on commitReset, a user who never needs a reset would
    // never accumulate a personal threshold.
    if (!wasCalibrated && index.isCalibrated) unawaited(flushState());

    notifyListeners();
  }

  // --- Actions ------------------------------------------------------------

  /// Start the guided reset. Load decays over the protocol so recovery is
  /// visible on the meter as it runs, rather than snapping at the end.
  void startReset() {
    if (_resetActive) return;

    _resetActive = true;
    _resetSecondsRemaining = resetDuration.inSeconds;
    // Only log resets taken against an established baseline, and only ones
    // measured through a signal worth believing. Before calibration finishes
    // the index has no personal reference to be measured against; through a
    // bad electrode it has no measurement at all. Either way the before/after
    // pair is a number without a meaning - and "reset effectiveness" is a
    // headline metric, so the one thing it must never contain is arithmetic
    // over an artifact.
    _startedAt = index.isCalibrated && signalGate.isUsable
        ? DateTime.now().toUtc()
        : null;
    _resetSignalClean = true;
    _loadBefore = index.value;
    // Null on real hardware, where recovery is the user's head doing the work
    // rather than the app arranging it. See [DemoControls.applyResetRecovery].
    source.demo?.applyResetRecovery();

    _resetTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _resetSecondsRemaining--;
      if (_resetSecondsRemaining <= 0) {
        _endReset(completed: true);
      } else {
        notifyListeners();
      }
    });

    notifyListeners();
  }

  /// Ended by the user before the protocol finished.
  void cancelReset() => _endReset(completed: false);

  void _endReset({required bool completed}) {
    _resetTimer?.cancel();
    _resetTimer = null;
    if (!_resetActive) return;

    _resetActive = false;
    _resetSecondsRemaining = 0;

    final startedAt = _startedAt;
    // A reset the signal went bad during is dropped entirely rather than
    // recorded with a caveat, which is what already happens to a reset taken
    // before calibration. Half a measurement in the effectiveness history is
    // worse than a gap in it: the gap is visible.
    if (startedAt != null && _resetSignalClean && signalGate.isUsable) {
      // Capture the after-reading now, not when the user answers the check-in:
      // they may sit on that screen, and the index keeps moving.
      _pending = _PendingReset(
        startedAt: startedAt,
        completed: completed,
        loadBefore: _loadBefore,
        loadAfter: index.value,
      );
    }
    _startedAt = null;

    notifyListeners();
  }

  /// Writes the finished reset, with [clarity] from the check-in when the user
  /// answered one. Safe to call when nothing is pending.
  Future<void> commitReset({int? clarity}) async {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;

    final record = ResetRecord(
      startedAt: pending.startedAt,
      completed: pending.completed,
      loadBefore: pending.loadBefore,
      loadAfter: pending.loadAfter,
      clarity: clarity,
    );

    final store = this.store;
    _resetHistory = store == null
        ? _resetHistory.add(record)
        : await store.append(
            _resetHistory,
            record,
            profile: index.profile,
            days: _foldToday(),
          );

    notifyListeners();
  }

  /// Persist the personal profile and today's rollup without a reset attached.
  /// Safe to call at any time, and a no-op with no store.
  Future<void> flushState() async {
    final store = this.store;
    if (store == null) {
      _foldToday();
      return;
    }
    await store.saveState(profile: index.profile, days: _foldToday());
  }

  /// Fold what this session has measured so far into the daily log and clear
  /// the accumulator, so repeated writes over one session do not count the
  /// same frames twice. Frames are attributed to the day they are *written*,
  /// which mis-files a session running across midnight - a day's resolution
  /// does not justify carrying a per-frame timestamp to fix it.
  DailyLoadLog _foldToday() {
    if (_dayFrames == 0) return _days;

    final now = DateTime.now();
    _days = _days.record(DailyLoad(
      day: DateTime(now.year, now.month, now.day),
      frames: _dayFrames,
      meanIndex: _daySum / _dayFrames,
      peakIndex: _dayPeak,
    ));

    _dayFrames = 0;
    _daySum = 0;
    _dayPeak = 0;
    return _days;
  }

  /// Demo control: drive the simulation directly rather than waiting on the
  /// scripted timeline. Being able to do this is what makes a live demo safe.
  void simulateStrain() {
    demo?.setLoadTarget(0.92, tauSeconds: 3.0);
    notifyListeners();
  }

  void simulateCalm() {
    demo?.setLoadTarget(0.15, tauSeconds: 3.0);
    notifyListeners();
  }

  /// Demo control: fail the electrode instead of the user.
  ///
  /// These are the ones worth showing. A detached electrode raises theta and
  /// suppresses alpha, so without the quality path the meter climbs into
  /// strain and the app offers a breathing protocol to somebody whose headband
  /// has come off. With it, the reading stops.
  void simulatePoorContact() {
    demo?.setContact(0.45);
    notifyListeners();
  }

  void simulateDetachedElectrode() {
    demo?.detachElectrode();
    notifyListeners();
  }

  void simulateGoodContact() {
    demo?.restoreContact();
    notifyListeners();
  }

  /// One second of samples lost, the way a missed BLE notification loses them.
  void simulateDropout({int samples = 256}) {
    demo?.dropSamples(samples);
    notifyListeners();
  }

  /// The radio drops, and comes back on the next call.
  ///
  /// The fault the dashboard has never been able to state: the electrode is
  /// fine, the user is fine, and the number on screen is minutes old.
  void simulateLinkDrop() {
    if (linkState == SourceLinkState.reconnecting) {
      demo?.restoreLink();
    } else {
      demo?.dropLink();
    }
    notifyListeners();
  }

  void recalibrate() {
    index.recalibrate();
    // The forecast is denominated in index points, and those are about to mean
    // something else.
    predictor.reset();
    _history.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    _subscription?.cancel();
    _qualitySubscription?.cancel();
    _linkSubscription?.cancel();
    source.dispose();
    engine.dispose();
    super.dispose();
  }
}

/// A finished reset held between the protocol ending and the check-in being
/// answered or dismissed.
class _PendingReset {
  final DateTime startedAt;
  final bool completed;
  final double loadBefore;
  final double loadAfter;

  const _PendingReset({
    required this.startedAt,
    required this.completed,
    required this.loadBefore,
    required this.loadAfter,
  });
}
