import '../dsp/dsp_engine.dart';
import '../services/eeg_data_stream.dart';
import '../services/signal_quality.dart';

/// Turns a per-block quality report into a per-*frame* verdict.
///
/// The source reports on the samples it has just delivered. The analysis does
/// not consume samples one at a time - it consumes a [DspConfig.windowSize]
/// window, so a fault that has already cleared keeps contaminating frames
/// until it has slid out the far end of that window. Two seconds of good
/// contact after an electrode is re-seated still produce two seconds of frames
/// half-built from the artifact.
///
/// Dropout is the sharpest version of this. The engine writes samples into a
/// ring buffer by position, so a gap is spliced out silently and the
/// Hann-windowed Goertzel turns the discontinuity into broadband splatter
/// landing in theta and alpha at once. The block that reports the gap is not
/// the only unusable one; every frame whose window still spans the splice is,
/// and only something counting samples is in a position to know when that
/// stops being true.
///
/// One mechanism covers both, and every other fault besides: after any
/// unusable report, a full window of usable samples has to pass before a frame
/// can be believed again. That interval is [SignalFault.settling].
class SignalQualityGate {
  SignalQuality _reported = SignalQuality.unreported;

  /// Usable samples delivered since the last unusable report. Starts full, so
  /// a gate that has seen nothing yet is not accusing anybody.
  int _usableSamples = DspConfig.windowSize;

  /// What was wrong when the window was last contaminated, so the settling
  /// interval can still say *why* it is settling. "Recovering" on its own
  /// tells a user nothing they can act on.
  Set<SignalFault> _faultsAtContamination = const {};

  /// The source's own measurements, as they stand: coupling, impedance,
  /// dropout count, measured rate.
  ///
  /// Read this for the numbers. Read [level] and [faults] for the verdict -
  /// they are the ones that account for the analysis window, and during a
  /// recovery they will disagree with `quality.level` on purpose.
  SignalQuality get quality => _reported;

  /// Whether the analysis window still contains samples from a fault that has
  /// since cleared.
  bool get isSettling =>
      _reported.isUsable && _usableSamples < DspConfig.windowSize;

  /// The verdict for a frame completing now.
  SignalQualityLevel get level =>
      isSettling ? SignalQualityLevel.unusable : _reported.level;

  /// Everything wrong with a frame completing now, including what was wrong
  /// when the window was contaminated if it is still settling.
  Set<SignalFault> get faults => isSettling
      ? {..._reported.faults, ..._faultsAtContamination, SignalFault.settling}
      : _reported.faults;

  /// Whether a reading taken now may be published at all.
  bool get isUsable => level != SignalQualityLevel.unusable;

  /// Whether a baseline may be captured from the signal as it stands.
  bool get isBaselineGrade => level == SignalQualityLevel.good;

  /// A report that arrived without samples behind it - a link that dropped, an
  /// impedance sweep between blocks.
  ///
  /// Idempotent with respect to [observeBlock], which calls it with the
  /// block's own report, so a source that publishes on both channels loses
  /// nothing and double-counts nothing.
  void observeQuality(SignalQuality quality) {
    _reported = quality;
    if (!quality.isUsable) {
      _usableSamples = 0;
      _faultsAtContamination = quality.faults;
    }
  }

  void observeBlock(SampleBlock block) {
    observeQuality(block.quality);

    // Samples from an unusable block do not count toward flushing the window -
    // they are what is being flushed. For a dropout that is one block's worth
    // of conservatism, since the samples *after* a gap are themselves fine;
    // the alternative is arithmetic on where inside the block the splice fell,
    // to save a quarter of a second.
    if (block.quality.isUsable) _usableSamples += block.length;
  }

  /// Treat the analysis window as contaminated by something the source has no
  /// way to report.
  ///
  /// One caller: the session coming back from being suspended. The samples on
  /// either side of that gap are individually fine and no report will ever say
  /// otherwise, but a window spanning the boundary is a splice - the same
  /// discontinuity a dropout produces, arriving through the operating system
  /// rather than through the radio. Requiring a full clean window afterwards
  /// is the mechanism that already exists for it.
  void contaminate(Set<SignalFault> faults) {
    _usableSamples = 0;
    _faultsAtContamination = faults;
  }

  void reset() {
    _reported = SignalQuality.unreported;
    _usableSamples = DspConfig.windowSize;
    _faultsAtContamination = const {};
  }
}
