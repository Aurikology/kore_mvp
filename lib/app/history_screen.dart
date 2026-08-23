import 'package:flutter/material.dart';

import '../session/reset_record.dart';
import '../theme/kore_theme.dart';
import '../widgets/stat_figure.dart';

/// Every reset, newest first, grouped by the day it happened on.
///
/// Reached by tapping the recovery card rather than from a tab bar. Two
/// destinations do not justify permanent navigation, and the card is already
/// showing a summary of what is behind it - which makes it the affordance, for
/// free, on a screen where a bottom bar would cost a decision on every other
/// screen too.
///
/// **Abandoned resets are shown.** They are greyed and labelled, not hidden:
/// how often a protocol is abandoned is a retention signal, and dropping them
/// from the list would flatter the record for the same reason
/// `ResetHistory.averageDrop` refuses to average them in. The session layer
/// already keeps them; this is the screen honouring that.
///
/// No celebration. No streak fire, no "great job". A reset either moved the
/// number or it did not, and the chip says which.
class HistoryScreen extends StatelessWidget {
  final ResetHistory history;

  /// Injected for the same reason `RecoveryCard` takes it: a single render
  /// must not straddle midnight, and "Today" has to be testable.
  final DateTime today;

  const HistoryScreen({
    super.key,
    required this.history,
    required this.today,
  });

  @override
  Widget build(BuildContext context) {
    final kore = context.kore;
    final text = Theme.of(context).textTheme;
    final days = groupByDay(history.records);

    return Scaffold(
      backgroundColor: kore.canvas,
      appBar: AppBar(
        title: Text('Session history',
            style: text.titleMedium?.copyWith(letterSpacing: 0.5)),
      ),
      body: SafeArea(
        child: days.isEmpty
            ? _empty(context)
            : ListView(
                padding: const EdgeInsets.fromLTRB(
                    KoreSpace.lg, KoreSpace.md, KoreSpace.lg, KoreSpace.xxl),
                children: [
                  _summary(context),
                  const SizedBox(height: KoreSpace.xl),
                  for (final day in days) ...[
                    _dayHeader(context, day.day),
                    const SizedBox(height: KoreSpace.sm),
                    Wrap(
                      spacing: KoreSpace.xs,
                      runSpacing: KoreSpace.xs,
                      children: [
                        for (final r in day.records) _ResetChip(record: r),
                      ],
                    ),
                    const SizedBox(height: KoreSpace.xl),
                  ],
                ],
              ),
      ),
    );
  }

  /// One line, no illustration, no apology. The user has not done anything
  /// wrong by not having a history yet.
  Widget _empty(BuildContext context) {
    final kore = context.kore;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(KoreSpace.xxl),
        child: Text(
          'Resets appear here once you have finished one.',
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(color: kore.textSecondary),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _summary(BuildContext context) {
    final streak = history.currentStreakDays(today);
    final drop = history.averageDrop;
    final clarity = history.averageClarity;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        StatFigure(
          value: streak > 0 ? '$streak' : '--',
          label: 'day streak',
          measured: streak > 0,
        ),
        StatFigure.orDash(
          value: drop?.round().toString(),
          label: 'avg drop',
        ),
        StatFigure.orDash(
          value: clarity?.toStringAsFixed(1),
          label: 'avg clarity',
        ),
      ],
    );
  }

  Widget _dayHeader(BuildContext context, DateTime day) {
    final kore = context.kore;
    return Row(
      children: [
        Text(
          labelForDay(day, today),
          style: Theme.of(context)
              .textTheme
              .labelMedium
              ?.copyWith(letterSpacing: KoreType.trackedLabel),
        ),
        const SizedBox(width: KoreSpace.sm),
        Expanded(child: Divider(height: 1, color: kore.border)),
      ],
    );
  }

  /// Today and yesterday are named; everything older is dated.
  ///
  /// Named days are the ones a user can place without arithmetic, and there
  /// are exactly two of them - "3 days ago" is a subtraction they have to do
  /// themselves and get wrong, and a date is not.
  static String labelForDay(DateTime day, DateTime today) {
    final t = DateTime(today.year, today.month, today.day);
    if (day == t) return 'TODAY';
    if (day == DateTime(t.year, t.month, t.day - 1)) return 'YESTERDAY';
    return '${day.day} ${_months[day.month - 1]}'.toUpperCase();
  }

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// Newest day first, and newest reset first within each day.
  ///
  /// `ResetHistory.records` is oldest-first because that is the order it is
  /// appended in and the order the streak arithmetic wants; a list someone
  /// scrolls wants the opposite, and reversing it here keeps the stored order
  /// alone.
  static List<HistoryDay> groupByDay(List<ResetRecord> records) {
    final byDay = <DateTime, List<ResetRecord>>{};
    for (final r in records) {
      byDay.putIfAbsent(r.localDay, () => []).add(r);
    }

    final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final d in days)
        HistoryDay(
          day: d,
          records: byDay[d]!.reversed.toList(),
        ),
    ];
  }
}

/// One day's resets, newest first.
class HistoryDay {
  final DateTime day;
  final List<ResetRecord> records;

  const HistoryDay({required this.day, required this.records});
}

/// A single reset: when, what it moved, and how clear the user said they felt.
class _ResetChip extends StatelessWidget {
  final ResetRecord record;

  const _ResetChip({required this.record});

  static String timeOf(DateTime at) {
    final l = at.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:'
        '${l.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final kore = context.kore;
    final text = Theme.of(context).textTheme;
    final abandoned = !record.completed;

    return Container(
      width: 132,
      // A floor, not a fixed height: an abandoned chip has less in it than a
      // completed one, and a row of chips at two different heights reads as
      // two different kinds of thing. Text that outgrows it still gets its
      // room.
      constraints: const BoxConstraints(minHeight: 96),
      padding: const EdgeInsets.all(KoreSpace.sm),
      decoration: BoxDecoration(
        color: kore.surface,
        borderRadius: BorderRadius.circular(KoreRadius.md),
        border: Border.all(color: kore.border),
      ),
      child: Semantics(
        label: abandoned
            ? 'Reset abandoned at ${timeOf(record.startedAt)}'
            : 'Reset at ${timeOf(record.startedAt)}, '
                '${_dropSentence(record.drop)}'
                '${record.clarity == null ? '' : ', clarity ${record.clarity} of 5'}',
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(timeOf(record.startedAt),
                    style: text.labelSmall?.copyWith(
                        color: abandoned ? kore.unmeasured : kore.textSecondary)),
                const Spacer(),
                if (record.clarity != null) _ClarityDots(rating: record.clarity!),
              ],
            ),
            const SizedBox(height: KoreSpace.sm),
            if (abandoned) ...[
              // No second line explaining that there is no measurement. The
              // absent figure is the explanation, and the word above it is
              // already the whole story.
              Text('ABANDONED',
                  style: text.labelSmall?.copyWith(
                      color: kore.unmeasured,
                      letterSpacing: KoreType.trackedLabel)),
            ] else ...[
              // Uncoloured on purpose, in both directions. The check-in sheet
              // states a rise in exactly the same secondary text as a fall,
              // and a history that painted the good ones green would be
              // grading the user rather than reporting the measurement. The
              // sign carries it.
              Text(
                _signed(record.drop),
                style: KoreType.numerals(
                  fontSize: KoreType.size24,
                  color: kore.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(record.drop >= 0 ? 'DROP' : 'RISE',
                  style: text.labelSmall?.copyWith(
                      color: kore.textSecondary,
                      letterSpacing: KoreType.trackedLabel)),
            ],
          ],
        ),
      ),
    );
  }

  static String _signed(double drop) {
    final rounded = drop.round();
    // A reset that moved nothing says zero rather than "-0", which is what
    // the raw formatting of a small negative produces.
    if (rounded == 0) return '0';
    return rounded > 0 ? '-$rounded' : '+${-rounded}';
  }

  static String _dropSentence(double drop) {
    final rounded = drop.round().abs();
    if (rounded == 0) return 'no change';
    return drop > 0 ? 'down $rounded points' : 'up $rounded points';
  }
}

/// Self-reported clarity, 1-5, as filled dots.
///
/// Dots rather than a numeral because the figure beside them is already a
/// number and two numbers in a chip that size are read as one. Never colour
/// alone: the count of filled dots is the reading, and it survives the colour
/// being discarded.
class _ClarityDots extends StatelessWidget {
  final int rating;

  const _ClarityDots({required this.rating});

  @override
  Widget build(BuildContext context) {
    final kore = context.kore;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i <= rating ? kore.accent : Colors.transparent,
                border: i <= rating ? null : Border.all(color: kore.border),
              ),
            ),
          ),
      ],
    );
  }
}
