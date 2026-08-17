import 'package:flutter_test/flutter_test.dart';
import 'package:kore/main.dart';

void main() {
  testWidgets('app boots and renders the KORE shell', (tester) async {
    await tester.pumpWidget(const KoreApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('KORE'), findsOneWidget);
    expect(find.text('Cognitive Load Index'), findsOneWidget);
  });
}
