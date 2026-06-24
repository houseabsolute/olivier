import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/settings/import_log_page.dart';
import 'package:olivier/state/import_log.dart';

void main() {
  testWidgets('titled "Activity & errors"', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        importLogFnProvider.overrideWithValue(() async => 'some line')
      ],
      child: const MaterialApp(home: ImportLogPage()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Activity & errors'), findsOneWidget);
  });

  testWidgets(
      'shows a message (not an infinite spinner) when the log read fails',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        importLogFnProvider
            .overrideWithValue(() async => throw Exception('read failed')),
      ],
      child: const MaterialApp(home: ImportLogPage()),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('read failed'), findsOneWidget);
  });
}
