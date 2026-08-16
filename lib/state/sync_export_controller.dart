import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/src/rust/api/sync.dart';
import 'package:olivier/state/providers.dart';
import 'package:path_provider/path_provider.dart';

/// Settings keys for the phone-snapshot export. The `sync_` prefix is load
/// bearing: the exporter strips these keys from the snapshot it writes, since
/// they hold desktop-local absolute paths.
const syncDestDirKey = 'sync_dest_dir';
const syncPhoneRootsKey = 'sync_phone_roots';

/// Where a Syncthing-replicated music folder usually lands on Android.
const defaultPhoneRoot = '/storage/emulated/0/Music';

/// Sentinel so [SyncExportState.copyWith] can distinguish "leave unchanged"
/// from "clear to null", matching [ScanState]'s convention.
const Object _unset = Object();

class SyncExportState {
  /// Folder the snapshot is written to — one Syncthing replicates to the phone.
  final String? destDir;

  /// Explicit phone location per library folder, keyed by the desktop root.
  /// A root absent from this map falls back to [defaultPhoneFor].
  final Map<String, String> phoneRoots;

  final bool exporting;

  /// Outcome of the last export: a summary, or the error that stopped it.
  final String? lastResult;
  final String? lastError;

  const SyncExportState({
    this.destDir,
    this.phoneRoots = const {},
    this.exporting = false,
    this.lastResult,
    this.lastError,
  });

  SyncExportState copyWith({
    Object? destDir = _unset,
    Map<String, String>? phoneRoots,
    bool? exporting,
    Object? lastResult = _unset,
    Object? lastError = _unset,
  }) {
    return SyncExportState(
      destDir: identical(destDir, _unset) ? this.destDir : destDir as String?,
      phoneRoots: phoneRoots ?? this.phoneRoots,
      exporting: exporting ?? this.exporting,
      lastResult: identical(lastResult, _unset)
          ? this.lastResult
          : lastResult as String?,
      lastError:
          identical(lastError, _unset) ? this.lastError : lastError as String?,
    );
  }

  /// The phone path this root will be rewritten to.
  String phoneRootFor(String root, List<String> allRoots) =>
      phoneRoots[root] ?? defaultPhoneFor(root, allRoots);
}

/// Default phone location for [root]. A single-folder library maps straight
/// onto [defaultPhoneRoot] — the overwhelmingly common Syncthing setup, and
/// what the user expects when they see one path. With several folders they
/// can't all be the same place, so each keeps its own name beneath it; those
/// are shown in the UI and can be edited.
String defaultPhoneFor(String root, List<String> allRoots) {
  if (allRoots.length <= 1) return defaultPhoneRoot;
  final name = _basename(root);
  return name.isEmpty ? defaultPhoneRoot : '$defaultPhoneRoot/$name';
}

String _basename(String path) {
  final parts = path.split('/').where((s) => s.isNotEmpty);
  return parts.isEmpty ? '' : parts.last;
}

/// Why a set of mappings can't be exported, or null if it's fine. Checked
/// before the FFI call so the user sees the problem in the UI, not a Rust
/// error string after the fact.
String? mappingProblem(List<RootMapping> mappings) {
  if (mappings.isEmpty) return 'No music folders to export.';
  for (final m in mappings) {
    if (!m.phone.startsWith('/')) {
      return 'Phone location for "${m.desktop}" must be an absolute path.';
    }
  }
  final seen = <String, String>{};
  for (final m in mappings) {
    final clash = seen[m.phone];
    if (clash != null) {
      return 'Two folders would both go to "${m.phone}": '
          '"$clash" and "${m.desktop}". Give them different locations.';
    }
    seen[m.phone] = m.desktop;
  }
  return null;
}

/// Seam so the controller is testable without the FFI or a real filesystem.
typedef ExportSnapshotFn = Future<SnapshotResult> Function({
  required String destDir,
  String? cacheDir,
  required List<RootMapping> mappings,
});

final exportSnapshotFnProvider = Provider<ExportSnapshotFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return ({required destDir, cacheDir, required mappings}) =>
      exportSyncSnapshot(
        dbPath: db,
        destDir: destDir,
        cacheDir: cacheDir,
        mappings: mappings,
      );
});

/// Resolves the on-disk cover cache, so the export can copy it. Seam.
typedef CacheDirFn = Future<String?> Function();

final cacheDirFnProvider = Provider<CacheDirFn>((ref) {
  return () async => (await getApplicationCacheDirectory()).path;
});

/// Drives "export a snapshot for the phone" from Settings.
class SyncExportController extends Notifier<SyncExportState> {
  /// The user has edited a field, so a late [hydrate] must not overwrite it —
  /// same guard as [LanguageLeadsNotifier].
  bool _userSet = false;
  bool _disposed = false;

  @override
  SyncExportState build() {
    ref.onDispose(() => _disposed = true);
    unawaited(hydrate());
    return const SyncExportState();
  }

  Future<void> hydrate() async {
    final get = ref.read(getSettingFnProvider);
    final dest = await get(syncDestDirKey);
    final roots = await get(syncPhoneRootsKey);
    if (_disposed || _userSet) return;
    state = state.copyWith(
      destDir: (dest != null && dest.isNotEmpty) ? dest : null,
      phoneRoots: _decodeRoots(roots),
    );
  }

  static Map<String, String> _decodeRoots(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      };
    } on FormatException {
      // A corrupt setting shouldn't wedge Settings; fall back to the defaults.
      return const {};
    }
  }

  Future<void> setDestDir(String dir) async {
    _userSet = true;
    state = state.copyWith(destDir: dir);
    await ref.read(setSettingFnProvider)(syncDestDirKey, dir);
  }

  /// Set where [root]'s files live on the phone. Throws nothing — an invalid
  /// path is reported by [mappingProblem] before any export runs.
  Future<void> setPhoneRoot(String root, String phonePath) async {
    _userSet = true;
    final next = {...state.phoneRoots, root: phonePath};
    state = state.copyWith(phoneRoots: next);
    await ref.read(setSettingFnProvider)(syncPhoneRootsKey, jsonEncode(next));
  }

  /// The rewrite that will be applied, one entry per library folder.
  List<RootMapping> mappingsFor(List<String> roots) => [
        for (final root in roots)
          RootMapping(desktop: root, phone: state.phoneRootFor(root, roots)),
      ];

  bool canExport(List<String> roots) =>
      state.destDir != null && !state.exporting && roots.isNotEmpty;

  /// Export only if the user has set up phone sync at all. The automatic
  /// post-scan path: silent when there is no destination folder (nobody asked
  /// for a snapshot) or an export is already running, but a *configured*
  /// destination with a broken mapping still goes through [export], so the
  /// problem lands in Settings instead of being swallowed.
  Future<void> exportIfConfigured(List<String> roots) async {
    if (state.destDir == null || state.exporting || roots.isEmpty) return;
    await export(roots);
  }

  Future<void> export(List<String> roots) async {
    final dest = state.destDir;
    if (dest == null || state.exporting) return;
    final mappings = mappingsFor(roots);
    final problem = mappingProblem(mappings);
    if (problem != null) {
      state = state.copyWith(lastError: problem, lastResult: null);
      return;
    }
    state = state.copyWith(exporting: true, lastError: null, lastResult: null);
    try {
      final cacheDir = await ref.read(cacheDirFnProvider)();
      final out = await ref.read(exportSnapshotFnProvider)(
        destDir: dest,
        cacheDir: cacheDir,
        mappings: mappings,
      );
      if (_disposed) return;
      state = state.copyWith(
        exporting: false,
        lastResult: '${out.files} tracks, ${out.coversCopied} covers → '
            '${out.dbPath}',
      );
    } catch (e) {
      if (_disposed) return;
      state = state.copyWith(exporting: false, lastError: '$e');
    }
  }
}

final syncExportControllerProvider =
    NotifierProvider<SyncExportController, SyncExportState>(
  SyncExportController.new,
);
