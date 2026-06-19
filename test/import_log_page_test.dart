import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/settings/import_log_page.dart';
import 'package:olivier/state/import_log.dart';

void main() {
  testWidgets('renders the log contents and Clear empties it', (tester) async {
    var contents = '=== Scan /m @ 2026-06-19 ===\nADD     track "T" — A\n';
    var cleared = false;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        importLogFnProvider.overrideWithValue(() async => contents),
        clearImportLogFnProvider.overrideWithValue(() async {
          cleared = true;
          contents = '';
        }),
      ],
      child: const MaterialApp(home: ImportLogPage()),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('ADD     track "T" — A'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear log'));
    await tester.pump();
    await tester.pump();

    expect(cleared, isTrue);
  });

  testWidgets('shows an empty state when the log is empty', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        importLogFnProvider.overrideWithValue(() async => ''),
        clearImportLogFnProvider.overrideWithValue(() async {}),
      ],
      child: const MaterialApp(home: ImportLogPage()),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('No import activity'), findsOneWidget);
  });
}
