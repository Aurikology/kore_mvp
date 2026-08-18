import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../dsp/cognitive_load_index.dart';
import '../dsp/dsp_engine.dart';
import '../dsp/dsp_engine_factory.dart';
import '../services/eeg_data_stream.dart';
import '../sources/simulated_eeg_source.dart';

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

  final ListQueue<double> _history = ListQueue<double>();

  StreamSubscription<List<EEGSample>>? _subscription;

  bool _resetActive = false;
  int _resetSecondsRemaining = 0;
  Timer? _resetTimer;

  KoreSession({SimulatedEegSource? source, DspEngine? engine})
      : source = source ?? SimulatedEegSource(),
        engine = engine ?? createDspEngine();

  // --- Read model for the UI ---------------------------------------------

  double get cognitiveLoad => index.value;

  LoadState get loadState => index.state;

  bool get isCalibrated => index.isCalibrated;

  double get calibrationProgress => index.calibrationProgress;

  int get calibrationSecondsRemaining =>
      index.secondsRemainingInCalibration.ceil();

  /// Oldest-to-newest index history, for the sparkline.
  List<double> get history => List.unmodifiable(_history);

  bool get resetActive => _resetActive;

  int get resetSecondsRemaining => _resetSecondsRemaining;

  double get resetProgress => _resetActive
      ? 1 - (_resetSecondsRemaining / resetDuration.inSeconds)
      : 0;

  String get backendLabel => engine.backendLabel;

  String get sourceLabel => source.label;

  bool get followingTimeline => source.autoTimeline;

  /// Simulated load level, surfaced only for the demo control row.
  double get simulatedLoad => source.generator.load;

  // --- Lifecycle ----------------------------------------------------------

  Future<void> start() async {
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

    index.update(frame);

    if (index.isCalibrated) {
      _history.addLast(index.value);
      while (_history.length > historyLength) {
        _history.removeFirst();
      }
    }

    notifyListeners();
  }

  // --- Actions ------------------------------------------------------------

  /// Start the guided reset. Load decays over the protocol so recovery is
  /// visible on the meter as it runs, rather than snapping at the end.
  void startReset() {
    if (_resetActive) return;

    _resetActive = true;
    _resetSecondsRemaining = resetDuration.inSeconds;
    source.applyResetRecovery();

    _resetTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _resetSecondsRemaining--;
      if (_resetSecondsRemaining <= 0) {
        cancelReset();
      } else {
        notifyListeners();
      }
    });

    notifyListeners();
  }

  void cancelReset() {
    _resetTimer?.cancel();
    _resetTimer = null;
    _resetActive = false;
    _resetSecondsRemaining = 0;
    notifyListeners();
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
