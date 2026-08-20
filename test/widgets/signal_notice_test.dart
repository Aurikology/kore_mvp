import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/services/signal_quality.dart';
import 'package:kore/theme/kore_theme.dart';
import 'package:kore/widgets/load_meter.dart';
import 'package:kore/widgets/signal_notice.dart';

/// The quality path's whole value is that the app refuses to publish a reading
/// it cannot support. These pin the other half of that promise: that the
/// refusal is *visible*, and that a held reading never looks like a live one.
void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
        MaterialApp(theme: KoreTheme.dark(), home: Scaffold(body: child)),
      );

  group('SignalNotice', () {
    testWidgets('says nothing when the signal is good', (tester) async {
      await pump(
          tester,
          const SignalNotice(
              level: SignalQualityLevel.good, faults: <SignalFault>{}));

      expect(find.byType(Text), findsNothing);
    });

    testWidgets('names the fault and the fix', (tester) async {
      await pump(
          tester,
          const SignalNotice(
            level: SignalQualityLevel.unusable,
            faults: {SignalFault.electrodeDetached},
          ),
      );

      expect(find.text('The electrode is not making contact'), findsOneWidget);
      // Unusable, so the sentence has to say that nothing is being kept -
      // otherwise a user reasonably assumes the session is still counting.
      expect(
          find.textContaining('Nothing is being recorded'), findsOneWidget);
    });

    testWidgets('softens the ask while the reading still publishes',
        (tester) async {
      await pump(
          tester,
          const SignalNotice(
            level: SignalQualityLevel.degraded,
            faults: {SignalFault.poorContact},
          ),
      );

      expect(find.text('Electrode contact is weak'), findsOneWidget);
      expect(find.textContaining('before it stops reading'), findsOneWidget);
    });

    testWidgets('explains a countdown that has stopped counting',
        (tester) async {
      await pump(
          tester,
          const SignalNotice(
            level: SignalQualityLevel.unusable,
            faults: {SignalFault.poorContact},
            calibrationStalled: true,
          ),
      );

      expect(find.textContaining('waiting rather than running'),
          findsOneWidget);
    });

    testWidgets('never borrows the strain colour for a fault', (tester) async {
      await pump(
          tester,
          const SignalNotice(
            level: SignalQualityLevel.unusable,
            faults: {SignalFault.dropout},
          ),
      );

      // A fault is not a reading. Colouring it like one would put a
      // cognitive-load colour on something that is not cognitive load.
      final style = tester
          .widget<Text>(find.text('Samples are not arriving'))
          .style!;
      expect(style.color, KoreColors.dark.unmeasured);
      expect(style.color, isNot(KoreColors.dark.strain));
    });
  });

  group('LoadMeter when stale', () {
    testWidgets('keeps the number but stops calling it current',
        (tester) async {
      await pump(tester,
          const Center(child: LoadMeter(value: 72, stale: true, size: 240)));
      await tester.pumpAndSettle();

      expect(find.text('72'), findsOneWidget);
      expect(find.text('LAST READING'), findsOneWidget);
      expect(find.text('COGNITIVE LOAD'), findsNothing);
    });

    testWidgets('paints the held value as unmeasured, not as a load colour',
        (tester) async {
      await pump(tester,
          const Center(child: LoadMeter(value: 72, stale: true, size: 240)));
      await tester.pumpAndSettle();

      // 72 is above the default threshold: live, this numeral would be near
      // the hot end of the ramp. Held, it must not be.
      final numeral = tester.widget<Text>(find.text('72')).style!;
      expect(numeral.color, KoreColors.dark.unmeasured);
      expect(numeral.color, isNot(KoreColors.dark.loadRamp.at(72)));
    });

    testWidgets('tells a screen reader the caveat before the number',
        (tester) async {
      await pump(tester,
          const Center(child: LoadMeter(value: 72, stale: true, size: 240)));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Signal lost. Last reading 72 out of 100'),
          findsOneWidget);
    });
  });
}
