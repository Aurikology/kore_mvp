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
import '../sources/simulated_eeg_source.dart';
import 'kore_history.dart';
import 'reset_record.dart';

/// Owns the live pipeline: source -> DSP engine -> Cognitive Load Index.
///
/// Notifies listeners **once per completed analysis frame (4 Hz)**, not once
/// per sample. The previous screen called setState() on every sample at
/// ~333 Hz, rebuilding the whole tree each time; here the 256 Hz acquisition
/// is fully decoupled from the repaint rate.
class KoreSession extends ChangeNotifier {
  static const int historyLength = 480; // 120 s at 4 Hz
  static const Duration resetDuration = Duration(seconds: 60);

  final SimulatedEegSource source;
  final DspEngine engine;
  final CognitiveLoadIndex index = CognitiveLoadIndex();
  final FocusCrashPredictor predictor = FocusCrashPredictor();

  /// Null means history lives in memory for this run only. The real store is
  /// wired at the composition root (`main`), which keeps widget tests from
  /// writing to the user's AppData just by pumping the app.
  final HistoryStore? store;

  final ListQueue<double> _history = ListQueue<double>();

  StreamSubscription<List<EEGSample>>? _subscription;

  bool _resetActive = false;
  int _resetSecondsRemaining = 0;
  Timer? _resetTimer;

  ResetHistory _resetHistory = ResetHistory.empty;
  DailyLoadLog _days = DailyLoadLog.empty;
  _PendingReset? _pending;
  DateTime? _startedAt;
  double _loadBefore = 0;

  // Today's rollup, accumulated over calibrated frames and folded into [_days]
  // whenever the session writes. Held separately rather than recomputed from
  // [_history] because that queue is 120 s long and a day is not.
  int _dayFrames = 0;
  double _daySum = 0;
  double _dayPeak = 0;

  KoreSession({SimulatedEegSource? source, DspEngine? engine, this.store})
      : source = source ?? SimulatedEegSource(),
        engine = engine ?? createDspEngine();

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

  double get calibrationProgress => index.calibrationProgress;

  int get calibrationSecondsRemaining =>
      index.secondsRemainingInCalibration.ceil();

  /// Oldest-to-newest index history, for the sparkline.
  List<double> get history => List.unmodifiable(_history);

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

  bool get followingTimeline => source.autoTimeline;

  /// Simulated load level, surfaced only for the demo control row.
  double get simulatedLoad => source.generator.load;

  // --- Lifecycle ----------------------------------------------------------

  Future<void> start() async {
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
    await source.start();
  }

  void _onBlock(List<EEGSample> block) {
    if (block.isEmpty) return;

    engine.pushBlock([
      for (final s in block)
        if (s.channels.isNotEmpty) s.channels[0],
    ]);

    final frame = engine.takeFrame();
    if (frame == null) return; // no new analysis window yet

    final wasCalibrated = index.isCalibrated;

    index.update(frame);
    predictor.observe(
      index: index.value,
      deviation: index.deviation,
      state: index.state,
      // The user's own threshold, not the default: forecasting a crossing of
      // a line the state machine is not using would warn about nothing.
      enterThreshold: index.strainEnter,
    );

    if (index.isCalibrated) {
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
    // Only log resets taken against an established baseline. Before
    // calibration finishes the index has no personal reference to be measured
    // against, so a before/after pair from that window would be a number
    // without a meaning - and "reset effectiveness" is a headline metric.
    _startedAt = index.isCalibrated ? DateTime.now().toUtc() : null;
    _loadBefore = index.value;
    source.applyResetRecovery();

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
    if (startedAt != null) {
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
    source.setLoadTarget(0.92, tauSeconds: 3.0);
    notifyListeners();
  }

  void simulateCalm() {
    source.setLoadTarget(0.15, tauSeconds: 3.0);
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
