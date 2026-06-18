import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/queue_panel.dart';

void main() {
  testWidgets('QueuePanel collapsed shell renders header + disabled controls',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 600, child: QueuePanel()),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Header label with the (placeholder) count.
    expect(find.text('Queue · 0'), findsOneWidget);
    // The three header controls + the expand caret are present.
    expect(find.byTooltip('Shuffle'), findsOneWidget);
    expect(find.byTooltip('Empty queue'), findsOneWidget);
    expect(find.byTooltip('Shuffle entire library'), findsOneWidget);
    expect(find.byTooltip('Expand queue'), findsOneWidget);

    // Everything is disabled in this slice (no data/wiring yet).
    final buttons = tester.widgetList<IconButton>(find.byType(IconButton));
    expect(buttons, isNotEmpty);
    for (final b in buttons) {
      expect(b.onPressed, isNull);
    }
  });
}
