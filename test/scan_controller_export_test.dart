import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/api/sync.dart';
import 'package:olivier/src/rust/catalog/scan.dart';
import 'package:olivier/state/enrich_controller.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/scan_controller.dart';
import 'package:olivier/state/sync_export_controller.dart';

/// Enrich stub that reports [entities] processed, so the tests can separate
/// "the scan changed files" from "only enrichment changed anything".
class _StubEnrich extends EnrichController {
  _StubEnrich(this.entities);
  final int entities;

  @override
  Future<void> enrich({bool force = false, bool clearCache = false}) async {
    state = state.copyWith(entitiesDone: entities);
  }
}

ScanProgress _progress(int changed) => ScanProgress(
      filesSeen: BigInt.from(changed),
      filesChanged: BigInt.from(changed),
      current: '',
      done: true,
    );

SnapshotResult _snapshot() => SnapshotResult(
      dbPath: '/sync/olivier-sync.db',
      files: 2,
      coversCopied: 1,
    );

void main() {
  /// Rescan every root, with [filesChanged] files changed per root and
  /// [entitiesEnriched] entities touched by the follow-up enrichment. Returns
  /// the destinations the exporter was asked to write to — empty if the scan
  /// published nothing.
  Future<List<String>> rescan({
    int filesChanged = 0,
    int entitiesEnriched = 0,
    String? destDir = '/sync',
    List<String> roots = const ['/m'],
  }) async {
    final exports = <String>[];
    final scanned = Completer<void>();
    final container = ProviderContainer(overrides: [
      dbPathProvider.overrideWithValue(':memory:'),
      listRootsFnProvider.overrideWithValue(() async => roots),
      scanLibraryFnProvider.overrideWithValue((_, __) {
        if (!scanned.isCompleted) scanned.complete();
        return Stream.value(_progress(filesChanged));
      }),
      enrichControllerProvider
          .overrideWith(() => _StubEnrich(entitiesEnriched)),
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

    // Read the export controller up front so its hydrate() has settled before
    // the scan finishes — otherwise the destination would still be null.
    container.read(syncExportControllerProvider);
    await Future<void>.delayed(Duration.zero);

    final c = container.read(scanControllerProvider.notifier);
    await c.loadRoots();
    c.rescanAll();
    await scanned.future;
    // Let the drain, the enrich pass and the export chain settle.
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return exports;
  }

  test('a scan that changed files exports a snapshot for the phone', () async {
    expect(await rescan(filesChanged: 3), ['/sync']);
  });

  test('leaves the export to enrichment when it enriched something', () async {
    // EnrichController publishes on its own way out, so exporting here too
    // would write the whole catalog and every cover into the sync folder
    // twice for one scan. (The stub enrich doesn't publish; the point of the
    // test is that the scan path stays out of the way.)
    expect(await rescan(filesChanged: 3, entitiesEnriched: 4), isEmpty);
  });

  test('an idle rescan leaves the sync folder alone', () async {
    // A full snapshot is a copy of the whole catalog plus every cover; writing
    // one on each no-op rescan would churn Syncthing for nothing.
    expect(await rescan(), isEmpty);
  });

  test('no destination folder means no export', () async {
    expect(await rescan(filesChanged: 3, destDir: null), isEmpty);
  });
}
