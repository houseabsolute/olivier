import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/settings/import_log_page.dart';
import 'package:olivier/settings/settings_page.dart';
import 'package:olivier/state/enrich_controller.dart';
import 'package:olivier/state/import_log.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/scan_controller.dart';

/// No-op scan controller: never touches the FFI.
class _StubScanController extends ScanController {
  @override
  ScanState build() => const ScanState();

  @override
  Future<void> loadRoots() async {}
}

/// No-op enrich controller: never touches the FFI.
class _StubEnrichController extends EnrichController {
  @override
  EnrichState build() => const EnrichState();
}

void main() {
  testWidgets('Settings has an Import log entry that opens the page',
      (tester) async {
    // Use a taller surface so the full Settings ListView can be scrolled into view.
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        scanControllerProvider.overrideWith(_StubScanController.new),
        enrichControllerProvider.overrideWith(_StubEnrichController.new),
        importLogFnProvider.overrideWithValue(() async => ''),
        clearImportLogFnProvider.overrideWithValue(() async {}),
      ],
      child: const MaterialApp(home: SettingsPage()),
    ));
    await tester.pumpAndSettle();

    final entry = find.text('Import log', skipOffstage: false);
    expect(entry, findsOneWidget);

    await tester.scrollUntilVisible(entry, 50);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(ImportLogPage), findsOneWidget);
  });
}
