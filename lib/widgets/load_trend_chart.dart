import 'package:flutter/material.dart';

import '../session/kore_history.dart';
import '../theme/kore_theme.dart';
import 'load_trend.dart';

/// A month of cognitive load, one bar per day.
///
/// The sparkline answers "where was I heading" over two minutes. This answers
/// the question three of the four product metrics are denominated in - "is
/// this getting better or worse over weeks" - and it is a different chart, not
/// a longer one. A line implies you were measured continuously between two
/// points, and nobody wears a patch for a fortnight without taking it off.
/// Separate bars claim only what was actually observed, and a day with no bar
/// is visibly a day with no data rather than a dip in a line.
///
/// Three channels carry each day and only one of them is colour: the bar's
/// height is the day's mean, the cap above it is that day's peak, and days
/// too short to count toward a trend are drawn muted. Discard colour and the
/// chart still orders two days correctly.
class LoadTrendChart extends StatelessWidget {
  final TrendWindow window;

  /// The threshold in force *now*, drawn as the same dashed rule the sparkline
  /// uses. Always the live value from the session - a rule at the published 70
  /// for a user whose own threshold has moved to 78 marks a line the state
  /// machine is not using.
  final double strainEnter;

  final double height;

  const LoadTrendChart({
    super.key,
    required this.window,
    required this.strainEnter,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    final k = context.kore;

    return Semantics(
      container: true,
      label: _semanticLabel(),
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _TrendPainter(
            slots: window.slots,
            strainEnter: strainEnter,
            colors: k,
          ),
        ),
      ),
    );
  }

  /// The bars are painted, and a painted bar is invisible to a screen reader.
  String _semanticLabel() {
    final peak = window.peakIndex;
    final shape = 'Daily cognitive load, ${window.measuredDays} of '
        '${window.span} days measured';
    return peak == null ? '$shape.' : '$shape, highest reading ${peak.round()}.';
  }
}

class _TrendPainter extends CustomPainter {
  final List<DailyLoad?> slots;
  final double strainEnter;
  final KoreColors colors;

  _TrendPainter({
    required this.slots,
    required this.strainEnter,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Fixed 0-100 scale, never fitted to the data in view. Rescaling would
    // make a calm fortnight and a strained one draw identically, and it would
    // put the threshold rule somewhere different every week.
    double y(double v) => size.height * (1 - (v / 100).clamp(0.0, 1.0));

    final baseline = Paint()
      ..color = colors.border
      ..strokeWidth = 1;

    final ruleY = y(strainEnter);
    for (double x = 0; x < size.width; x += KoreTrend.dashPeriod) {
      canvas.drawLine(
          Offset(x, ruleY), Offset(x + KoreTrend.dashMark, ruleY), baseline);
    }

    // The floor, so bars sit on something rather than float.
    canvas.drawLine(
        Offset(0, size.height), Offset(size.width, size.height), baseline);

    if (slots.isEmpty) return;

    final slot = size.width / slots.length;
    final barWidth = KoreTrend.barWidth(size.width, slots.length);

    for (var i = 0; i < slots.length; i++) {
      final day = slots[i];
      if (day == null) continue; // a gap is a gap, never a zero

      // Below the log's minimum a day's mean is whatever the user happened to
      // be doing in the minute the app was open, so it is shown in the same
      // colour "no measurement" always takes rather than borrowing a reading's
      // place on the ramp.
      final counts = day.frames >= DailyLoadLog.minFramesForTrend;
      final color = counts
          ? colors.forLoad(day.meanIndex)
          : colors.unmeasured.withValues(alpha: KoreTrend.shortDayAlpha);

      final left = i * slot + (slot - barWidth) / 2;
      final top = y(day.meanIndex);

      canvas.drawRRect(
        RRect.fromRectAndCorners(
          // At least a hairline of bar for a day that measured a near-zero
          // load: an invisible bar is indistinguishable from a missing day.
          Rect.fromLTRB(left, top.clamp(0.0, size.height - 1), left + barWidth,
              size.height),
          topLeft: const Radius.circular(KoreTrend.barRadius),
          topRight: const Radius.circular(KoreTrend.barRadius),
        ),
        Paint()..color = color,
      );

      // The peak, as a cap above the mean. Quieter than the bar, because the
      // mean is the reading and the peak is only its context.
      if (day.peakIndex > day.meanIndex) {
        final capY = y(day.peakIndex);
        canvas.drawRect(
          Rect.fromLTWH(left, capY, barWidth, KoreTrend.peakCapHeight),
          Paint()..color = color.withValues(alpha: KoreTrend.peakAlpha),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.strainEnter != strainEnter ||
      old.colors != colors ||
      old.slots.length != slots.length ||
      // The log changes only when the session writes, which is at most once
      // per reset - so the last slot's identity is a sufficient check for a
      // chart that is otherwise rebuilt at 4 Hz behind an unchanged dataset.
      (slots.isNotEmpty && !identical(old.slots.last, slots.last));
}
