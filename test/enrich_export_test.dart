import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/api/sync.dart';
import 'package:olivier/src/rust/enrich/progress.dart';
import 'package:olivier/state/enrich_controller.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/sync_export_controller.dart';

EnrichProgress _progress(int entities) => EnrichProgress(
      entitiesDone: BigInt.from(entities),
      entitiesTotal: BigInt.from(entities),
      current: 'A',
      done: true,
    );

SnapshotResult _snapshot() => SnapshotResult(
      dbPath: '/sync/olivier-sync.db',
      files: 2,
      coversCopied: 1,
    );

void main() {
  /// Re-fetch one artist, whose pass reports [entities] enriched. Returns the
  /// destinations the exporter was asked to write to.
  Future<List<String>> enrichArtist({
    required int entities,
    String? destDir = '/sync',
    List<String> roots = const ['/m'],
  }) async {
    final exports = <String>[];
    final container = ProviderContainer(overrides: [
      dbPathProvider.overrideWithValue(':memory:'),
      listRootsFnProvider.overrideWithValue(() async => roots),
      enrichArtistFnProvider.overrideWithValue(
        (mbid) => Stream.value(_progress(entities)),
      ),
      getSettingFnProvider.overrideWithValue(
        (key) async => key == syncDestDirKey ? destDir : null,
      ),
      setSettingFnProvider.overrideWithValue((_, __) async {}),
      cacheDirFnProvider.overrideWithValue(() async => '/cache'),
      exportSnapshotFnProvider.overrideWithValue(
        ({required destDir, cacheDir, required mappings}) {
          exports.add(destDir);
          return Future.value(_snapshot());
        },
      ),
    ]);
    addTearDown(container.dispose);

    // Let the export controller's hydrate() settle, or the destination would
    // still be null when the enrichment finishes.
    container.read(syncExportControllerProvider);
    await Future<void>.delayed(Duration.zero);

    await container.read(enrichControllerProvider.notifier).enrichArtist('A');
    return exports;
  }

  test('enriching an artist publishes a fresh snapshot', () async {
    // Transliterations and title alts are catalog changes like any other; the
    // phone is out of date until they are exported.
    expect(await enrichArtist(entities: 1), ['/sync']);
  });

  test('a pass that enriched nothing writes no snapshot', () async {
    expect(await enrichArtist(entities: 0), isEmpty);
  });

  test('no destination folder means no export', () async {
    expect(await enrichArtist(entities: 1, destDir: null), isEmpty);
  });
}
