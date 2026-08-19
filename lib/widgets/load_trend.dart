import '../session/kore_history.dart';

/// The daily log, aligned to a fixed span of calendar days ending today.
///
/// The log stores only the days it measured something on. A chart needs the
/// days it *did not*, in their proper places, or a fortnight with three gaps
/// in it draws as an unbroken run of three days. Every empty slot here is a
/// day KORE was not measuring, and it is drawn as a gap rather than as a zero.
class TrendWindow {
  /// Local midnight of the most recent slot.
  final DateTime today;

  /// Oldest first, one entry per calendar day, null where nothing was
  /// measured. Length is always the requested span.
  final List<DailyLoad?> slots;

  const TrendWindow._(this.today, this.slots);

  factory TrendWindow.of(
    DailyLoadLog log, {
    required DateTime today,
    required int span,
  }) {
    final end = DateTime(today.year, today.month, today.day);

    // Keyed by calendar date rather than by an offset in days: the difference
    // between two local midnights across a daylight-saving boundary is 23 or
    // 25 hours, and truncating that to whole days files the reading under the
    // wrong bar.
    final byDay = <String, DailyLoad>{
      for (final d in log.days) _key(d.day): d,
    };

    return TrendWindow._(end, [
      for (var i = span - 1; i >= 0; i--)
        byDay[_key(DateTime(end.year, end.month, end.day - i))],
    ]);
  }

  int get span => slots.length;

  DateTime get firstDay =>
      DateTime(today.year, today.month, today.day - (span - 1));

  Iterable<DailyLoad> get measured => slots.whereType<DailyLoad>();

  int get measuredDays => measured.length;

  /// Days carrying enough measured load to count toward a trend.
  ///
  /// The rule is the log's, not this layer's - but the *count* is not on the
  /// log's read model, and the refusal copy has to name it ("one day so far").
  /// If `_within` ever changes what it considers inside a window, this
  /// re-derivation of the same boundary is what drifts; the test that pairs
  /// this count with `trendPerDay`'s refusal is what catches it.
  int get qualifyingDays => measured
      .where((d) => d.frames >= DailyLoadLog.minFramesForTrend)
      .length;

  /// Highest single reading in the window, over every measured day including
  /// the short ones. A peak is an observation rather than an average, so a
  /// ten-minute session's peak is as real as a four-hour one's - it is only
  /// the *mean* that a short day distorts.
  double? get peakIndex {
    double? peak;
    for (final d in measured) {
      if (peak == null || d.peakIndex > peak) peak = d.peakIndex;
    }
    return peak;
  }

  static String _key(DateTime d) => '${d.year}-${d.month}-${d.day}';

  /// `5 Aug`. Hand-rolled because the project takes no pub dependencies, and
  /// an axis end label is not worth `intl`.
  static String shortDate(DateTime d) => '${d.day} ${_months[d.month - 1]}';

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
}

/// The trend stated in words, including when there is no trend to state.
///
/// Separated from the widget for the same reason `ForecastNotice.phrase` is:
/// the copy is the honesty rule, and a rule that can only be checked by
/// pumping a widget and reading pixels does not get checked.
///
/// Two things it deliberately does not do. It never colours a direction - a
/// rising line is rendered exactly as a falling one, because KORE has no alarm
/// colour and a load that went up is a measurement, not a verdict on someone.
/// And it never says "worse" or "better": the words are **rising** and
/// **easing**, which describe the number rather than judging the person behind
/// it.
class TrendStatement {
  /// The sentence. Always present; there is no state in which the card shows
  /// an empty box.
  final String headline;

  /// The qualification underneath it - the mean and the threshold when there
  /// is a trend, the reason there is not when there is not.
  final String detail;

  /// False when the log refused to fit a line. The chart still draws whatever
  /// days exist; only the direction is withheld.
  final bool hasTrend;

  const TrendStatement({
    required this.headline,
    required this.detail,
    required this.hasTrend,
  });

  /// The log will not fit a line through fewer than this many qualifying days.
  /// Mirrored here so the copy can name the number rather than describing it
  /// vaguely as "a few".
  static const int minQualifyingDays = 3;

  /// Below one index point a week, no direction is named.
  ///
  /// The same call `ForecastNotice` makes when it rounds to five seconds: this
  /// is a least-squares line through at most a fortnight of daily means, and
  /// half a point a week is inside the noise of when someone opened the app.
  static const double minPointsPerWeek = 1.0;

  factory TrendStatement.of(
    DailyLoadLog log, {
    required TrendWindow window,
    required double strainEnter,
    required bool thresholdsPersonalised,
  }) {
    final span = window.span;
    final qualifying = window.qualifyingDays;

    if (qualifying < minQualifyingDays) {
      return TrendStatement(
        headline: window.measuredDays == 0
            ? 'Nothing measured in the last $span days.'
            : 'Not enough measured days to call a trend.',
        detail: _whyNot(qualifying),
        hasTrend: false,
      );
    }

    final perDay = log.trendPerDay(window.today, window: span);
    if (perDay == null) {
      // Reachable only if the qualifying days collapse to a single date, which
      // the log's own merge rule makes impossible - but a refusal it makes and
      // this layer ignores would be a line drawn through nothing.
      return const TrendStatement(
        headline: 'No trend to draw yet.',
        detail: 'The measured days are too close together to fit a line '
            'through.',
        hasTrend: false,
      );
    }

    final perWeek = perDay * 7;
    final magnitude = perWeek.abs().round();
    final headline = perWeek.abs() < minPointsPerWeek
        ? 'Your load is holding steady over the last $span days.'
        : '${perWeek > 0 ? 'Your load is rising' : 'Your load is easing'} '
            '— about $magnitude '
            '${magnitude == 1 ? 'point' : 'points'} a week.';

    final mean = log.meanIndexOverLastDays(window.today, span);
    final owner = thresholdsPersonalised ? 'your' : 'the strain';

    return TrendStatement(
      headline: headline,
      detail: mean == null
          ? 'Fitted across $qualifying measured days.'
          : 'Mean ${mean.round()} across $qualifying measured days, against '
              '$owner threshold of ${strainEnter.round()}.',
      hasTrend: true,
    );
  }

  /// Names what is missing rather than how much is there. "You have two" reads
  /// as a score; "a trend needs three" reads as a rule, and a rule is
  /// something the user can satisfy.
  static String _whyNot(int qualifying) {
    final have = switch (qualifying) {
      0 => 'No day yet has',
      1 => 'One day so far has',
      2 => 'Two days so far have',
      _ => '$qualifying days so far have',
    };
    // Spelled from the log's own constant rather than typed as prose, so
    // retuning what a day has to carry cannot leave the copy claiming a
    // minute that is no longer the rule.
    final minutes = DailyLoadLog.minFramesForTrend / 240;
    final required =
        minutes <= 1 ? 'a full minute' : '${minutes.round()} minutes';

    return '$have $required of measured load. A trend needs '
        '$minQualifyingDays, so KORE is not drawing a line through fewer.';
  }
}
