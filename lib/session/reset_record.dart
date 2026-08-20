/// One pass through the detect -> reset -> confirm loop.
///
/// [loadBefore] and [loadAfter] are Cognitive Load Index readings taken at the
/// moment the protocol started and the moment it ended, so [drop] is measured
/// rather than asserted. On the current build the recovery it measures is a
/// simulated one - `applyResetRecovery()` decays the synthetic load - so the
/// arithmetic here is real while the physiology behind it is not yet.
class ResetRecord {
  /// Always stored in UTC; only ever rendered in local time.
  final DateTime startedAt;

  /// False when the user ended the protocol early. Aborted resets are kept
  /// rather than dropped: how often a reset is abandoned is a retention
  /// signal, and silently discarding them would flatter the averages.
  final bool completed;

  final double loadBefore;
  final double loadAfter;

  /// 1-5 self-report, or null when the check-in was skipped or not offered.
  final int? clarity;

  const ResetRecord({
    required this.startedAt,
    required this.completed,
    required this.loadBefore,
    required this.loadAfter,
    this.clarity,
  });

  /// Positive means the index fell over the protocol.
  double get drop => loadBefore - loadAfter;

  /// The calendar day this reset belongs to, in local time, normalised to
  /// midnight. Streaks are a human-facing idea, so they run on the user's
  /// days, not on UTC days.
  DateTime get localDay {
    final l = startedAt.toLocal();
    return DateTime(l.year, l.month, l.day);
  }

  Map<String, Object?> toJson() => {
        'startedAt': startedAt.toUtc().toIso8601String(),
        'completed': completed,
        'loadBefore': loadBefore,
        'loadAfter': loadAfter,
        if (clarity != null) 'clarity': clarity,
      };

  /// Returns null for anything unparseable. A single bad entry - a truncated
  /// write, a hand-edited file - should cost that one record, not the whole
  /// history.
  static ResetRecord? tryFromJson(Object? raw) {
    if (raw is! Map) return null;

    final started = DateTime.tryParse(raw['startedAt']?.toString() ?? '');
    if (started == null) return null;

    final before = _asDouble(raw['loadBefore']);
    final after = _asDouble(raw['loadAfter']);
    if (before == null || after == null) return null;
    if (!before.isFinite || !after.isFinite) return null;

    final clarity = raw['clarity'];
    return ResetRecord(
      startedAt: started.toUtc(),
      completed: raw['completed'] == true,
      loadBefore: before,
      loadAfter: after,
      clarity: clarity is int && clarity >= 1 && clarity <= 5 ? clarity : null,
    );
  }

  static double? _asDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}

/// Derived view over the stored records: the numbers the dashboard shows and
/// the ones `docs/positioning.md` lists as key metrics.
///
/// Deliberately free of I/O and of `DateTime.now()` - `today` is passed in - so
/// every figure here is directly testable.
class ResetHistory {
  /// Oldest first.
  final List<ResetRecord> records;

  const ResetHistory(this.records);

  static const ResetHistory empty = ResetHistory([]);

  int get totalCount => records.length;

  Iterable<ResetRecord> get _completed => records.where((r) => r.completed);

  int get completedCount => _completed.length;

  /// Mean index drop across completed resets, or null before the first one.
  /// Aborted resets are excluded here: a protocol ended after four seconds
  /// says nothing about whether the protocol works.
  double? get averageDrop {
    final done = _completed.toList();
    if (done.isEmpty) return null;
    final sum = done.fold<double>(0, (a, r) => a + r.drop);
    return sum / done.length;
  }

  /// Mean self-reported clarity over resets where the user actually answered.
  double? get averageClarity {
    final rated = records.where((r) => r.clarity != null).toList();
    if (rated.isEmpty) return null;
    final sum = rated.fold<int>(0, (a, r) => a + r.clarity!);
    return sum / rated.length;
  }

  /// Consecutive days, counting back, on which at least one reset completed.
  ///
  /// A streak that has not been extended *today* is not broken yet - it breaks
  /// once a day passes with nothing in it. Zeroing the count at midnight would
  /// punish the user for not having reset before breakfast.
  int currentStreakDays(DateTime today) {
    final days = <DateTime>{for (final r in _completed) r.localDay};
    if (days.isEmpty) return 0;

    var cursor = DateTime(today.year, today.month, today.day);
    if (!days.contains(cursor)) {
      cursor = cursor.subtract(const Duration(days: 1));
      if (!days.contains(cursor)) return 0;
    }

    var streak = 0;
    while (days.contains(cursor)) {
      streak++;
      // Step back via the constructor, not `subtract(Duration(days: 1))`: a
      // Duration is a fixed span of hours, so on a DST boundary it lands at
      // 23:00 or 01:00 of the wrong day. Out-of-range day values are
      // normalised, including across month and year ends.
      cursor = DateTime(cursor.year, cursor.month, cursor.day - 1);
    }
    return streak;
  }

  /// Number of completed resets on the [days] most recent local days,
  /// inclusive of today.
  int completedInLastDays(DateTime today, int days) {
    final cutoff = DateTime(today.year, today.month, today.day - (days - 1));
    return _completed.where((r) => !r.localDay.isBefore(cutoff)).length;
  }

  ResetHistory add(ResetRecord r) => ResetHistory([...records, r]);
}
