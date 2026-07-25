import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/src/rust/api/sync.dart';
import 'package:olivier/state/providers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Where the desktop's snapshot lands once Syncthing has replicated it. The
/// export is written into the music folder itself, so the phone needs no
/// configuration: the snapshot arrives beside the audio it describes.
const defaultSyncSourceDir = '/storage/emulated/0/Music';

/// Overrides [defaultSyncSourceDir] when the library syncs somewhere else.
/// `sync_` prefixed so the exporter strips it from any snapshot (it is a
/// device-local path).
const syncSourceDirKey = 'sync_source_dir';

/// Outcome of the last import attempt, surfaced in Settings.
class SyncImportState {
  final bool running;

  /// Human-readable result of the last attempt, if there was one.
  final String? lastResult;
  final String? lastError;

  /// Whether all-files access has been granted. The snapshot is a `.db`, which
  /// `READ_MEDIA_AUDIO` cannot reach, so without this there is nothing to
  /// import and no audio to play.
  final bool hasStoragePermission;

  const SyncImportState({
    this.running = false,
    this.lastResult,
    this.lastError,
    this.hasStoragePermission = false,
  });

  SyncImportState copyWith({
    bool? running,
    String? lastResult,
    String? lastError,
    bool? hasStoragePermission,
  }) =>
      SyncImportState(
        running: running ?? this.running,
        lastResult: lastResult ?? this.lastResult,
        lastError: lastError ?? this.lastError,
        hasStoragePermission: hasStoragePermission ?? this.hasStoragePermission,
      );
}

/// Seams, so the controller is testable without the FFI, a real filesystem or
/// a permission dialog.
typedef ImportSnapshotFn = Future<ImportResult> Function({
  required String srcDir,
  required String dbPath,
  String? cacheDir,
});

final importSnapshotFnProvider = Provider<ImportSnapshotFn>((ref) {
  return ({required srcDir, required dbPath, cacheDir}) =>
      importSyncSnapshot(srcDir: srcDir, dbPath: dbPath, cacheDir: cacheDir);
});

typedef StoragePermissionFn = Future<bool> Function();

/// Requests all-files access. Android shows a settings screen rather than a
/// dialog for this one, so the user leaves the app and comes back.
final storagePermissionFnProvider = Provider<StoragePermissionFn>((ref) {
  return () async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    final status = await Permission.manageExternalStorage.request();
    return status.isGranted;
  };
});

final storagePermissionStatusFnProvider = Provider<StoragePermissionFn>((ref) {
  return () async {
    if (!Platform.isAndroid) return true;
    return Permission.manageExternalStorage.isGranted;
  };
});

typedef ImportCacheDirFn = Future<String?> Function();

final importCacheDirFnProvider = Provider<ImportCacheDirFn>((ref) {
  return () async => (await getApplicationCacheDirectory()).path;
});

/// Adopts the desktop's snapshot as this device's catalog.
class SyncImportController extends Notifier<SyncImportState> {
  bool _disposed = false;

  @override
  SyncImportState build() {
    ref.onDispose(() => _disposed = true);
    return const SyncImportState();
  }

  Future<String> _sourceDir() async {
    final configured = await ref.read(getSettingFnProvider)(syncSourceDirKey);
    return (configured != null && configured.isNotEmpty)
        ? configured
        : defaultSyncSourceDir;
  }

  Future<void> setSourceDir(String dir) async {
    await ref.read(setSettingFnProvider)(syncSourceDirKey, dir);
  }

  Future<void> refreshPermission() async {
    final granted = await ref.read(storagePermissionStatusFnProvider)();
    if (_disposed) return;
    state = state.copyWith(hasStoragePermission: granted);
  }

  Future<bool> requestPermission() async {
    final granted = await ref.read(storagePermissionFnProvider)();
    if (_disposed) return granted;
    state = state.copyWith(hasStoragePermission: granted);
    return granted;
  }

  /// Import if there is a newer snapshot. [interactive] requests the storage
  /// permission when it's missing; the startup path passes false so a cold
  /// start never blocks on a system screen.
  Future<void> importIfNewer({bool interactive = false}) async {
    if (state.running) return;
    state = state.copyWith(running: true, lastError: null);
    try {
      final granted = interactive
          ? await ref.read(storagePermissionFnProvider)()
          : await ref.read(storagePermissionStatusFnProvider)();
      if (_disposed) return;
      state = state.copyWith(hasStoragePermission: granted);
      if (!granted) {
        state = state.copyWith(
          running: false,
          lastError: 'Storage access is needed to read the synced library.',
        );
        return;
      }
      final out = await ref.read(importSnapshotFnProvider)(
        srcDir: await _sourceDir(),
        dbPath: ref.read(dbPathProvider),
        cacheDir: await ref.read(importCacheDirFnProvider)(),
      );
      if (_disposed) return;
      state = state.copyWith(
        running: false,
        lastResult: out.imported
            ? 'Imported ${out.files} tracks, ${out.coversCopied} covers'
            : out.reason,
      );
    } catch (e) {
      if (_disposed) return;
      state = state.copyWith(running: false, lastError: '$e');
    }
  }
}

final syncImportControllerProvider =
    NotifierProvider<SyncImportController, SyncImportState>(
  SyncImportController.new,
);
