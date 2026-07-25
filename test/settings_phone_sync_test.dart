import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/settings/settings_page.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/scan_controller.dart';
import 'package:olivier/state/sync_export_controller.dart';

/// Settings renders scan/enrich state too, so stub every FFI seam it touches.
ProviderContainer _container({
  List<String> roots = const [],
  Map<String, String> settings = const {},
}) {
  final store = {...settings};
  return ProviderContainer(overrides: [
    dbPathProvider.overrideWithValue(':memory:'),
    getSettingFnProvider.overrideWithValue((key) async => store[key]),
    setSettingFnProvider.overrideWithValue((key, value) async {
      store[key] = value;
    }),
    listRootsFnProvider.overrideWithValue(() async => roots),
    cacheDirFnProvider.overrideWithValue(() async => '/cache'),
  ]);
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  // Tall surface so the Phone sync section — near the bottom of a lazy
  // ListView — is actually laid out and findable.
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // ScanController doesn't load roots in build(); the app calls this at startup.
  await container.read(scanControllerProvider.notifier).loadRoots();
  await container.read(syncExportControllerProvider.notifier).hydrate();
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: SettingsPage()),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the phone location for each library folder',
      (tester) async {
    final container = _container(roots: ['/home/me/Music']);
    addTearDown(container.dispose);
    await _pump(tester, container);

    expect(find.text('Phone sync'), findsOneWidget);
    // A single folder maps straight onto the phone root — no appended name.
    expect(find.text('on the phone:  $defaultPhoneRoot'), findsOneWidget);
  });

  testWidgets('several folders each get their own destination', (tester) async {
    final container =
        _container(roots: ['/home/me/Music', '/mnt/archive/FLAC']);
    addTearDown(container.dispose);
    await _pump(tester, container);

    expect(find.text('on the phone:  $defaultPhoneRoot/Music'), findsOneWidget);
    expect(find.text('on the phone:  $defaultPhoneRoot/FLAC'), findsOneWidget);
  });

  testWidgets('renders without throwing for a degenerate root', (tester) async {
    // add_root stores "" for a root of "/" — this must not red-screen the page.
    final container = _container(roots: ['', '/home/me/Music']);
    addTearDown(container.dispose);
    await _pump(tester, container);

    expect(tester.takeException(), isNull);
    expect(find.text('Phone sync'), findsOneWidget);
  });

  testWidgets('the export button is disabled until a destination is set',
      (tester) async {
    final container = _container(roots: ['/home/me/Music']);
    addTearDown(container.dispose);
    await _pump(tester, container);

    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Export for phone'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('a colliding mapping is reported before any export',
      (tester) async {
    final container = _container(
      roots: ['/a/Music', '/b/Music'],
      settings: {
        syncDestDirKey: '/sync',
        syncPhoneRootsKey:
            '{"/a/Music":"/sdcard/Music","/b/Music":"/sdcard/Music"}',
      },
    );
    addTearDown(container.dispose);
    await _pump(tester, container);

    expect(find.textContaining('both go to'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Export for phone'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull, reason: 'export must stay blocked');
  });
}
