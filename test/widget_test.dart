import 'package:flutter_test/flutter_test.dart';
import 'package:kore/main.dart';
import 'package:kore/widgets/load_meter.dart';

void main() {
  testWidgets('app boots into the dashboard, calibrating', (tester) async {
    await tester.pumpWidget(const KoreApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('KORE'), findsOneWidget);
    expect(find.byType(LoadMeter), findsOneWidget);

    // No baseline yet, so the meter must be in its calibrating state rather
    // than showing a number it cannot justify.
    expect(find.text('CALIBRATING'), findsOneWidget);
    expect(find.text('Run a reset'), findsOneWidget);

    // The demo must never imply hardware that is not attached.
    expect(find.text('Simulated signal'), findsOneWidget);
  });
}
