import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/src/rust/api/cover.dart' as cover;
import 'package:olivier/state/providers.dart';
import 'package:path_provider/path_provider.dart';

/// Resolves the OS app-cache directory once (shared with playback's cover cache).
final coverCacheDirProvider = FutureProvider<String>((ref) async {
  final dir = await getApplicationCacheDirectory();
  return dir.path;
});

/// FFI seam: resolve a cover path for a release MBID. Overridden in tests.
typedef CoverForReleaseFn = Future<String?> Function(String releaseMbid);

final coverForReleaseFnProvider = Provider<CoverForReleaseFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (releaseMbid) async {
    final cacheDir = await ref.read(coverCacheDirProvider.future);
    return cover.coverForRelease(
        dbPath: db, releaseMbid: releaseMbid, cacheDir: cacheDir);
  };
});

/// FFI seam: resolve a cover path for an audio file path. Overridden in tests.
typedef CoverForPathFn = Future<String?> Function(String filePath);

final coverForPathFnProvider = Provider<CoverForPathFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (filePath) async {
    final cacheDir = await ref.read(coverCacheDirProvider.future);
    return cover.coverForPath(
        dbPath: db, filePath: filePath, cacheDir: cacheDir);
  };
});

/// Cached cover path per release MBID. keepAlive so scrolling back doesn't
/// re-run the FFI; errors degrade to null (placeholder).
final albumCoverProvider =
    FutureProvider.family<String?, String>((ref, releaseMbid) async {
  ref.keepAlive();
  try {
    return await ref.read(coverForReleaseFnProvider)(releaseMbid);
  } catch (_) {
    return null;
  }
});

/// Cover path for an audio file (now-playing track). Errors degrade to null.
final pathCoverProvider =
    FutureProvider.family<String?, String>((ref, filePath) async {
  ref.keepAlive();
  try {
    return await ref.read(coverForPathFnProvider)(filePath);
  } catch (_) {
    return null;
  }
});
