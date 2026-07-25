import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/artist_column.dart';
import 'package:olivier/settings/settings_page.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/capabilities.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';
import 'package:olivier/state/scan_controller.dart';
import 'package:olivier/state/sync_import_controller.dart';

const _artist = Artist(
  mbid: 'a1',
  name: 'Ringo Sheena',
  sortName: 'Sheena, Ringo',
  transliteration: null,
  nameOriginal: null,
);

class _EmptyQueue extends QueueNotifier {
  @override
  Future<QueueView> build() async => QueueView.empty;
}

class _StubScanController extends ScanController {
  @override
  ScanState build() => const ScanState(roots: ['/music']);

  @override
  Future<void> loadRoots() async {}
}

ProviderContainer _container({required bool canModify}) {
  final container = ProviderContainer(overrides: [
    dbPathProvider.overrideWithValue(':memory:'),
    getSettingFnProvider.overrideWithValue((key) async => null),
    setSettingFnProvider.overrideWithValue((key, value) async {}),
    artistsProvider.overrideWith((ref) => [_artist]),
    scanControllerProvider.overrideWith(_StubScanController.new),
    queueProvider.overrideWith(_EmptyQueue.new),
    importCacheDirFnProvider.overrideWithValue(() async => '/cache'),
    storagePermissionStatusFnProvider.overrideWithValue(() async => true),
    storagePermissionFnProvider.overrideWithValue(() async => true),
    canModifyCatalogProvider.overrideWithValue(canModify),
  ]);
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpSettings(WidgetTester tester, ProviderContainer c) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: const MaterialApp(home: SettingsPage()),
  ));
  await tester.pumpAndSettle();
}

Future<void> _pumpArtists(WidgetTester tester, ProviderContainer c) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: const MaterialApp(
      home: Scaffold(body: ArtistColumn(narrow: true)),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('Settings', () {
    testWidgets('a read-only device hides scanning and enrichment',
        (tester) async {
      await _pumpSettings(tester, _container(canModify: false));

      // These would rewrite the catalog the desktop owns.
      expect(find.text('Music folders'), findsNothing);
      expect(find.text('Add folder'), findsNothing);
      expect(find.text('Rescan all'), findsNothing);
      expect(find.text('Check for new music'), findsNothing);
      expect(find.text('Enrich library'), findsNothing);
      expect(find.text('Re-fetch from MusicBrainz'), findsNothing);
      // Exporting a snapshot is meaningless without a catalog of one's own.
      expect(find.text('Export for phone'), findsNothing);

      // What the device does own stays.
      expect(find.text('Synced library'), findsOneWidget);
      expect(find.text('Display'), findsOneWidget);
      expect(find.text('Diagnostics'), findsOneWidget);
    });

    testWidgets('the desktop keeps all of it', (tester) async {
      await _pumpSettings(tester, _container(canModify: true));

      expect(find.text('Music folders'), findsOneWidget);
      expect(find.text('Add folder'), findsOneWidget);
      expect(find.text('Enrich library'), findsOneWidget);
      expect(find.text('Export for phone'), findsOneWidget);
      expect(find.text('Synced library'), findsNothing,
          reason: 'the import section is for the synced device');
    });
  });

  group('row context menu', () {
    testWidgets('a read-only device offers no catalog edits', (tester) async {
      await _pumpArtists(tester, _container(canModify: false));

      await tester.longPress(find.text('Ringo Sheena'));
      await tester.pumpAndSettle();

      expect(find.text('Re-fetch from MusicBrainz'), findsNothing);
      expect(find.text('Set reading…'), findsNothing);
      // Queue and playlist actions are device-local, so they remain.
      expect(find.text('Add to queue'), findsOneWidget);
      expect(find.text('Add to playlist…'), findsOneWidget);
    });

    testWidgets('the desktop keeps the editing entries', (tester) async {
      await _pumpArtists(tester, _container(canModify: true));

      await tester.longPress(find.text('Ringo Sheena'));
      await tester.pumpAndSettle();

      expect(find.text('Re-fetch from MusicBrainz'), findsOneWidget);
      expect(find.text('Set reading…'), findsOneWidget);
    });
  });
}
