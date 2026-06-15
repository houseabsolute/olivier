import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/src/rust/api/catalog.dart';
import 'package:olivier/state/providers.dart';

/// Sentinel so [ScanState.copyWith] can distinguish "leave lastError unchanged"
/// from "clear lastError to null".
const Object _unset = Object();

/// Snapshot of the library-scan subsystem, watched by the UI.
class ScanState {
  /// Persisted root folders, ordered by path.
  final List<String> roots;

  /// A scan run is currently in progress (it may cover several queued folders).
  final bool scanning;

  /// Live progress of the folder currently being scanned.
  final int filesSeen;
  final int filesChanged;

  /// Folders still waiting behind the one being scanned.
  final int queued;

  /// Error from the folder most recently scanned, or null if it succeeded.
  /// Reset at the start of each folder so each scan reports its own outcome.
  final String? lastError;

  const ScanState({
    this.roots = const [],
    this.scanning = false,
    this.filesSeen = 0,
    this.filesChanged = 0,
    this.queued = 0,
    this.lastError,
  });

  ScanState copyWith({
    List<String>? roots,
    bool? scanning,
    int? filesSeen,
    int? filesChanged,
    int? queued,
    Object? lastError = _unset,
  }) {
    return ScanState(
      roots: roots ?? this.roots,
      scanning: scanning ?? this.scanning,
      filesSeen: filesSeen ?? this.filesSeen,
      filesChanged: filesChanged ?? this.filesChanged,
      queued: queued ?? this.queued,
      lastError:
          identical(lastError, _unset) ? this.lastError : lastError as String?,
    );
  }
}

/// Owns the persisted set of library root folders and a serialized scan queue.
///
/// SQLite is single-writer, so scans must not overlap. Adding a folder while one
/// is already running enqueues it; the queue drains one folder at a time. Each
/// folder is scanned on its own (`scanLibrary(roots: [dir])`), which — together
/// with the path-scoped deletion sweep in the Rust scanner — means adding a
/// folder never deletes files belonging to a different folder.
class ScanController extends Notifier<ScanState> {
  final List<String> _queue = [];
  bool _draining = false;
  bool _disposed = false;

  @override
  ScanState build() {
    // The drain loop is a detached future; guard its state writes so a dispose
    // mid-scan can't throw UnmountedRefException from an unawaited future.
    ref.onDispose(() => _disposed = true);
    return const ScanState();
  }

  /// Load persisted roots into state. Call once at startup. Merges with any
  /// roots already present so an addFolder() racing ahead isn't dropped.
  Future<void> loadRoots() async {
    final db = ref.read(dbPathProvider);
    final persisted = await listRoots(dbPath: db);
    if (_disposed) return;
    final merged = {...persisted, ...state.roots}.toList()..sort();
    state = state.copyWith(roots: merged);
  }

  /// Persist [dir] as a library root and scan it. Safe to call while another
  /// scan is running — the folder is queued.
  Future<void> addFolder(String dir) async {
    final db = ref.read(dbPathProvider);
    await addRoot(dbPath: db, path: dir);
    if (_disposed) return;
    if (!state.roots.contains(dir)) {
      state = state.copyWith(roots: [...state.roots, dir]..sort());
    }
    _enqueue(dir);
  }

  /// Re-scan every known root.
  void rescanAll() {
    for (final r in state.roots) {
      _enqueue(r);
    }
  }

  /// Forget [dir] and remove the files beneath it. Also drops it from the
  /// pending queue so it isn't immediately re-scanned. (A scan already in flight
  /// for [dir] is not cancelled; removing a folder mid-scan of itself is a
  /// Settings-page concern and not yet exposed in the UI.)
  Future<void> removeFolder(String dir) async {
    final db = ref.read(dbPathProvider);
    _queue.removeWhere((r) => r == dir);
    await removeRoot(dbPath: db, path: dir);
    if (_disposed) return;
    state = state.copyWith(
      roots: state.roots.where((r) => r != dir).toList(),
      queued: _queue.length,
    );
    ref.invalidate(artistsProvider);
  }

  void _enqueue(String dir) {
    _queue.add(dir);
    state = state.copyWith(queued: _queue.length);
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    final db = ref.read(dbPathProvider);
    try {
      while (_queue.isNotEmpty) {
        final root = _queue.removeAt(0);
        // Skip a root the user removed while it sat in the queue.
        if (!state.roots.contains(root)) {
          state = state.copyWith(queued: _queue.length);
          continue;
        }
        state = state.copyWith(
          scanning: true,
          filesSeen: 0,
          filesChanged: 0,
          queued: _queue.length,
          lastError: null,
        );
        try {
          await for (final p in scanLibrary(dbPath: db, roots: [root])) {
            if (_disposed) return;
            state = state.copyWith(
              filesSeen: p.filesSeen.toInt(),
              filesChanged: p.filesChanged.toInt(),
            );
            if (p.done) break;
          }
        } catch (e) {
          if (_disposed) return;
          state = state.copyWith(lastError: '$e');
        }
        if (_disposed) return;
        // New music may have appeared — refresh the browser's artist list.
        ref.invalidate(artistsProvider);
      }
    } finally {
      _draining = false;
      if (!_disposed) state = state.copyWith(scanning: false, queued: 0);
    }
  }
}

final scanControllerProvider =
    NotifierProvider<ScanController, ScanState>(ScanController.new);
