import 'dart:math' as math;

/// What KORE knows about one user's load that outlives a single session.
///
/// Two things are personal and both drift on a scale of days, not minutes:
///
/// - **The resting log theta/alpha ratio.** The index already measures against
///   a baseline, but that baseline is captured in the first 15 s of whatever
///   session happens to be starting. A user who sits down already strained
///   calibrates against a strained ratio and then reads "steady" for the rest
///   of the hour. Keeping a long-run baseline is what lets that capture be
///   sanity-checked instead of trusted blindly.
///
/// - **The distribution the index actually occupies.** 70 and 60 are the right
///   thresholds for the population the constants were tuned against. For a
///   user whose index habitually sits at 78 they are not thresholds at all,
///   they are a permanent alarm.
///
/// Immutable, so every update is a value the caller can persist, compare, or
/// throw away. One small allocation per analysis frame, alongside the
/// `BandPowers` the frame already produces.
class LoadProfile {
  /// Frames of index history the distribution is allowed to remember.
  ///
  /// 12,000 is 50 minutes of measured load at 4 Hz. Past that the running
  /// statistics forget exponentially rather than freezing, so a profile keeps
  /// tracking a user whose baseline genuinely moves - a term ending, a sleep
  /// schedule repairing itself - instead of being pinned by their first week.
  static const int kMaxIndexFrames = 12000;

  /// How far a session's fresh baseline capture moves the long-run one.
  ///
  /// A quarter of the way, so a single strange day cannot relocate the
  /// personal baseline; four consecutive ones can.
  static const double kBaselineLearningRate = 0.25;

  /// Long-run resting log theta/alpha ratio, or null for a user with no
  /// history. Null is the cold-start signal, and every consumer treats it as
  /// "defer entirely to this session's capture".
  final double? baselineLogRatio;

  /// Running mean and variance of the Cognitive Load Index over calibrated
  /// frames. Exponentially weighted once [indexFrames] reaches
  /// [kMaxIndexFrames]; exactly the sample statistics before that.
  final double indexMean;
  final double indexVariance;

  /// Frames behind [indexMean], saturating at [kMaxIndexFrames]. Consumers
  /// read this to decide whether there is enough of the user on record to
  /// personalise anything.
  final int indexFrames;

  /// Completed baseline captures, i.e. sessions that got as far as calibrating.
  final int sessionCount;

  const LoadProfile({
    this.baselineLogRatio,
    this.indexMean = 0,
    this.indexVariance = 0,
    this.indexFrames = 0,
    this.sessionCount = 0,
  });

  /// A user the app has never seen. Every published number is reproducible
  /// from this.
  static const LoadProfile fresh = LoadProfile();

  double get indexSd => math.sqrt(indexVariance);

  bool get hasBaseline => baselineLogRatio != null;

  /// Fold one calibrated frame's index into the running distribution.
  ///
  /// West's incremental exponentially-weighted variance, with the weight
  /// pinned to 1/n while n is below the cap. Below the cap that is exactly the
  /// population mean and variance; above it, it forgets. Doing it in one
  /// update rather than switching estimators at the boundary means there is no
  /// discontinuity in the thresholds derived from it.
  LoadProfile withIndexFrame(double index) {
    if (!index.isFinite) return this;

    final n = math.min(indexFrames + 1, kMaxIndexFrames);
    final a = 1.0 / n;
    final delta = index - indexMean;
    final mean = indexMean + a * delta;
    final variance = (1 - a) * (indexVariance + a * delta * delta);

    return LoadProfile(
      baselineLogRatio: baselineLogRatio,
      indexMean: mean,
      indexVariance: variance,
      indexFrames: n,
      sessionCount: sessionCount,
    );
  }

  /// Fold a session's freshly captured baseline in.
  ///
  /// The *raw* capture is what learns, not the value the session ended up
  /// using: if a capture was pulled back toward the personal baseline because
  /// it looked like it happened during strain, and it turns out the user has
  /// genuinely shifted, only the raw observations can carry the profile there.
  LoadProfile withSessionBaseline(double capturedLogRatio) {
    if (!capturedLogRatio.isFinite) return this;

    final previous = baselineLogRatio;
    return LoadProfile(
      baselineLogRatio: previous == null
          ? capturedLogRatio
          : previous + kBaselineLearningRate * (capturedLogRatio - previous),
      indexMean: indexMean,
      indexVariance: indexVariance,
      indexFrames: indexFrames,
      sessionCount: sessionCount + 1,
    );
  }

  Map<String, Object?> toJson() => {
        if (baselineLogRatio != null) 'baselineLogRatio': baselineLogRatio,
        'indexMean': indexMean,
        'indexVariance': indexVariance,
        'indexFrames': indexFrames,
        'sessionCount': sessionCount,
      };

  /// Returns null for anything unparseable, in the same spirit as
  /// `ResetRecord.tryFromJson`: a hand-edited or truncated profile costs the
  /// personalisation, not the app. The caller falls back to [fresh], which is
  /// the documented cold-start behaviour and is always safe.
  static LoadProfile? tryFromJson(Object? raw) {
    if (raw is! Map) return null;

    final baseline = _finite(raw['baselineLogRatio']);
    final mean = _finite(raw['indexMean']) ?? 0.0;
    final variance = _finite(raw['indexVariance']) ?? 0.0;

    // A negative variance or a negative count means the file was edited.
    // Clamping rather than rejecting keeps whatever else was in there usable.
    return LoadProfile(
      baselineLogRatio: baseline,
      indexMean: mean,
      indexVariance: math.max(0.0, variance),
      indexFrames: _count(raw['indexFrames']).clamp(0, kMaxIndexFrames),
      sessionCount: _count(raw['sessionCount']),
    );
  }

  static double? _finite(Object? v) {
    final d = v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
    return d != null && d.isFinite ? d : null;
  }

  static int _count(Object? v) {
    final d = _finite(v);
    return d == null || d < 0 ? 0 : d.round();
  }

  @override
  String toString() => 'LoadProfile(baseline: '
      '${baselineLogRatio?.toStringAsFixed(3) ?? '-'}, '
      'index: ${indexMean.toStringAsFixed(1)} +/- '
      '${indexSd.toStringAsFixed(1)} over $indexFrames frames, '
      'sessions: $sessionCount)';
}
