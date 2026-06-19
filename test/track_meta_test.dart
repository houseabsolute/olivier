import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/widgets/track_meta.dart';

void main() {
  testWidgets('shows length + added date + last-played date', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TrackMeta(
          lengthMs: BigInt.from(258000), // 4:18
          addedAt: 1718800000, // 2024-06-19
          lastPlayed: 1718900000, // 2024-06-20
        ),
      ),
    ));
    expect(find.text('4:18'), findsOneWidget);
    expect(find.text('2024-06-19'), findsOneWidget);
    expect(find.text('2024-06-20'), findsOneWidget);
  });

  testWidgets('shows — when never played', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TrackMeta(lengthMs: null, addedAt: 0, lastPlayed: null),
      ),
    ));
    expect(find.text('—'), findsNWidgets(2)); // added (0) + last-played (null)
  });
}
