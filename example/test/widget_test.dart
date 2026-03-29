import 'package:flutter_test/flutter_test.dart';

import 'package:pion_bridge_example/main.dart';

void main() {
  testWidgets('Throughput test app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ThroughputTestApp());

    expect(find.text('P2P Throughput Test'), findsOneWidget);
    expect(find.text('Start Test'), findsOneWidget);
  });
}
