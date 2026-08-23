import '../dsp/load_profile.dart';
import 'reset_record.dart';

/// One local day of measured cognitive load, rolled up.
///
/// The reset log answers "did the protocol help". This answers the slower
/// question underneath it - "is this person's load trending anywhere" - which
/// no amount of reset records can, because a user who never resets still has a
/// trend. Per-day rather than per-frame because 4 Hz for a term is tens of
/// millions of numbers to answer a question with a resolution of days.
class DailyLoad {
  /// Local midnight. Trends are a human-facing idea, so they run on the user's
  /// days, exactly as streaks do.
  final DateTime day;

  /// Calibrated analysis frames behind [meanIndex]. Kept so days can be merged
  /// correctly across several sessions, and so a ten-second app open is
  /// distinguishable from an afternoon of work.
  final int frames;

  final double meanIndex;
  final double peakIndex;

  const DailyLoad({
    required this.day,
    required this.frames,
    required this.meanIndex,
    required this.peakIndex,
  });

  double get minutes => frames / 240.0; // 4 Hz

  /// Fold [other] - the same local day, from a later session - into this one.
  /// The mean is weighted by frames; anything else would let a two-minute
  /// session count as much as a two-hour one.
  DailyLoad merge(DailyLoad other) {
    final total = frames + other.frames;
    if (total <= 0) return this;
    return DailyLoad(
      day: day,
      frames: total,
      meanIndex: (meanIndex * frames + other.meanIndex * other.frames) / total,
      peakIndex: peakIndex > other.peakIndex ? peakIndex : other.peakIndex,
    );
  }

  Map<String, Object?> toJson() => {
        'day': _dayString(day),
        'frames': frames,
        'meanIndex': meanIndex,
        'peakIndex': peakIndex,
      };

  static DailyLoad? tryFromJson(Object? raw) {
    if (raw is! Map) return null;

    final parsed = DateTime.tryParse(raw['day']?.toString() ?? '');
    if (parsed == null) return null;

    final mean = _finite(raw['meanIndex']);
    final peak = _finite(raw['peakIndex']);
    final frames = _finite(raw['frames']);
    if (mean == null || peak == null || frames == null || frames < 0) {
      return null;
    }

    return DailyLoad(
      day: DateTime(parsed.year, parsed.month, parsed.day),
      frames: frames.round(),
      meanIndex: mean,
      peakIndex: peak,
    );
  }

  static String _dayString(DateTime d) => '${d.year.toString().padLeft(4, '0')}'
      '-${d.month.toString().padLeft(2, '0')}'
      '-${d.day.toString().padLeft(2, '0')}';

  static double? _finite(Object? v) {
    final d = v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
    return d != null && d.isFinite ? d : null;
  }
}

/// The longitudinal record: one [DailyLoad] per day the app measured anything.
///
/// Free of I/O and of `DateTime.now()` - `today` is passed in - for the same
/// reason [ResetHistory] is: every figure it produces has to be directly
/// testable.
class DailyLoadLog {
  /// Roughly two terms. Bounded here rather than in the store so the in-memory
  /// log is bounded too, and so the file cannot grow without the code that
  /// owns the growth being the code that caps it.
  static const int maxDays = 180;

  /// A day needs this much measured load before it counts toward a trend. One
  /// minute. Below it the daily mean is dominated by whatever the user was
  /// doing in the moment they opened the app.
  static const int minFramesForTrend = 240;

  /// Oldest first.
  final List<DailyLoad> days;

  const DailyLoadLog(this.days);

  static const DailyLoadLog empty = DailyLoadLog([]);

  bool get isEmpty => days.isEmpty;

  DailyLoad? get latest => days.isEmpty ? null : days.last;

  /// Fold [entry] in, merging into the existing record for that day if there
  /// is one, and dropping the oldest days past [maxDays].
  DailyLoadLog record(DailyLoad entry) {
    if (entry.frames <= 0) return this;

    final merged = <DailyLoad>[];
    var placed = false;
    for (final d in days) {
      if (d.day == entry.day) {
        merged.add(d.merge(entry));
        placed = true;
      } else {
        merged.add(d);
      }
    }
    if (!placed) merged.add(entry);

    merged.sort((a, b) => a.day.compareTo(b.day));
    return DailyLoadLog(merged.length > maxDays
        ? merged.sublist(merged.length - maxDays)
        : merged);
  }

  /// Frame-weighted mean index over the [window] most recent local days,
  /// inclusive of [today]. Null when nothing in that window carries enough
  /// measured load to mean anything.
  double? meanIndexOverLastDays(DateTime today, int window) {
    final entries = _within(today, window);
    var frames = 0;
    var sum = 0.0;
    for (final d in entries) {
      frames += d.frames;
      sum += d.meanIndex * d.frames;
    }
    return frames == 0 ? null : sum / frames;
  }

  /// Index points per day, fitted across the [window] most recent days that
  /// carry at least [minFramesForTrend] frames. Positive means load is
  /// climbing week over week.
  ///
  /// Null below three qualifying days: two points always fit a line perfectly,
  /// and reporting a trend from them would be reporting the noise between two
  /// mornings as a direction of travel.
  double? trendPerDay(DateTime today, {int window = 14}) {
    final entries = _within(today, window)
        .where((d) => d.frames >= minFramesForTrend)
        .toList();
    if (entries.length < 3) return null;

    final origin = entries.first.day;
    var meanX = 0.0, meanY = 0.0;
    for (final d in entries) {
      meanX += d.day.difference(origin).inDays.toDouble();
      meanY += d.meanIndex;
    }
    meanX /= entries.length;
    meanY /= entries.length;

    var sxx = 0.0, sxy = 0.0;
    for (final d in entries) {
      final dx = d.day.difference(origin).inDays.toDouble() - meanX;
      sxx += dx * dx;
      sxy += dx * (d.meanIndex - meanY);
    }
    return sxx <= 0 ? null : sxy / sxx;
  }

  Iterable<DailyLoad> _within(DateTime today, int window) {
    final cutoff = DateTime(today.year, today.month, today.day - (window - 1));
    final end = DateTime(today.year, today.month, today.day);
    return days.where((d) => !d.day.isBefore(cutoff) && !d.day.isAfter(end));
  }

  List<Object?> toJson() => [for (final d in days) d.toJson()];

  static DailyLoadLog fromJson(Object? raw) {
    if (raw is! List) return empty;
    final parsed = <DailyLoad>[];
    for (final entry in raw) {
      final d = DailyLoad.tryFromJson(entry);
      if (d != null) parsed.add(d);
    }
    parsed.sort((a, b) => a.day.compareTo(b.day));
    return DailyLoadLog(parsed.length > maxDays
        ? parsed.sublist(parsed.length - maxDays)
        : parsed);
  }
}

/// What the app itself remembers between runs, as distinct from what it has
/// measured.
///
/// One field so far, and it earns the section: without it the first run cannot
/// be told from the hundredth, and the welcome screen either never appears or
/// appears every time. It sits in the same document as the history rather than
/// in a second file because the store's read-modify-write already guarantees
/// that two writers cannot erase each other's half, and a second file would
/// need that guarantee again from scratch.
///
/// Nothing here is a preference. Settings, if they ever exist, are a different
/// question from "has this person seen the claim boundary yet", and mixing
/// them would make this section a junk drawer.
class AppState {
  /// When the user finished the first-run flow, or null if they never have.
  ///
  /// A timestamp rather than a bool because the useful questions later are
  /// about *when* - whether a baseline predates the last re-seating, whether
  /// the claim boundary was shown before or after a copy change - and a bool
  /// answers none of them.
  final DateTime? onboardingCompletedAt;

  const AppState({this.onboardingCompletedAt});

  static const AppState empty = AppState();

  bool get hasOnboarded => onboardingCompletedAt != null;

  Map<String, Object?> toJson() => {
        if (onboardingCompletedAt != null)
          'onboardingCompletedAt': onboardingCompletedAt!.toIso8601String(),
      };

  /// Anything unparseable reads as "not yet onboarded", which shows the
  /// welcome screen a second time. That is the safe direction to fail: the
  /// cost is one avoidable screen, where the other direction skips the claim
  /// boundary entirely.
  static AppState fromJson(Object? raw) {
    if (raw is! Map) return empty;
    final at = DateTime.tryParse(raw['onboardingCompletedAt']?.toString() ?? '');
    return AppState(onboardingCompletedAt: at);
  }
}

/// Everything KORE keeps on disk, as one document.
///
/// v1 was a bare JSON array of reset records. It had nowhere to put the
/// personal baseline and thresholds that make the index mean the same thing
/// from one session to the next, and nowhere to put a longitudinal record that
/// survives the reset log being trimmed. v2 is an object with a version tag,
/// and [fromJson] reads both - a v1 file is migrated on the next write rather
/// than discarded, because those records are the user's streak. v3 adds
/// [AppState], and reads exactly the same way: a v2 file has no `app` key, so
/// the section reads empty and upgrades on the next write.
class KoreHistory {
  static const int formatVersion = 3;

  final ResetHistory resets;
  final LoadProfile profile;
  final DailyLoadLog days;
  final AppState app;

  const KoreHistory({
    required this.resets,
    required this.profile,
    required this.days,
    this.app = AppState.empty,
  });

  static const KoreHistory empty = KoreHistory(
    resets: ResetHistory.empty,
    profile: LoadProfile.fresh,
    days: DailyLoadLog.empty,
  );

  KoreHistory copyWith({
    ResetHistory? resets,
    LoadProfile? profile,
    DailyLoadLog? days,
    AppState? app,
  }) =>
      KoreHistory(
        resets: resets ?? this.resets,
        profile: profile ?? this.profile,
        days: days ?? this.days,
        app: app ?? this.app,
      );

  Map<String, Object?> toJson() => {
        'version': formatVersion,
        'resets': [for (final r in resets.records) r.toJson()],
        'profile': profile.toJson(),
        'days': days.toJson(),
        'app': app.toJson(),
      };

  /// Reads either format. Anything unrecognisable reads as [empty], in the
  /// same spirit as the per-record parsers: a file that cannot be understood
  /// costs the history, never the app.
  static KoreHistory fromJson(Object? decoded) {
    // v1: the whole file was the record list.
    if (decoded is List) {
      return KoreHistory(
        resets: _resetsFrom(decoded),
        profile: LoadProfile.fresh,
        days: DailyLoadLog.empty,
      );
    }

    if (decoded is! Map) return empty;

    return KoreHistory(
      resets: _resetsFrom(decoded['resets']),
      profile: LoadProfile.tryFromJson(decoded['profile']) ?? LoadProfile.fresh,
      days: DailyLoadLog.fromJson(decoded['days']),
      app: AppState.fromJson(decoded['app']),
    );
  }

  static ResetHistory _resetsFrom(Object? raw) {
    if (raw is! List) return ResetHistory.empty;
    final records = <ResetRecord>[];
    for (final entry in raw) {
      final r = ResetRecord.tryFromJson(entry);
      if (r != null) records.add(r);
    }
    records.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return ResetHistory(records);
  }
}
