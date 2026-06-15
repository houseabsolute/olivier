import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:olivier/audio/audio_handler.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/api/catalog.dart';
import 'package:olivier/src/rust/api/tags.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:path_provider/path_provider.dart';

class PlaybackController {
  PlaybackController({
    required this.audioHandler,
    required this.queueController,
    required this.dbPath,
  }) {
    _subscribeIndex();
    _subscribePlayTracking();
  }

  final OlivierAudioHandler audioHandler;
  final QueueController queueController;
  final String dbPath;

  // Mirrors the current queue's MediaItems so we can look up by index.
  List<MediaItem> _currentItems = [];

  // Lazily resolved application cache directory (memoised Future).
  Future<String>? _cacheDirFuture;

  // Per-file cover path cache so we don't re-call the FFI on repeated plays.
  // A null value means "we already tried and the file has no embedded art".
  final Map<String, String?> _coverCache = {};

  // Play-tracking state.
  int? _trackedIndex;
  bool _recordedForCurrentTrack = false;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _playerStateSub;

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  Future<void> playAlbum(
    String releaseMbid,
    String albumTitle, {
    int initialIndex = 0,
  }) async {
    final paths =
        await albumFilePaths(dbPath: dbPath, releaseMbid: releaseMbid);
    final tracks = await listTracks(dbPath: dbPath, releaseMbid: releaseMbid);

    final items = _buildItems(paths, tracks, albumTitle);
    await _applyQueue(items, paths, initialIndex);
    await audioHandler.play();
  }

  Future<void> playTrack(
    String releaseMbid,
    String albumTitle,
    int index,
  ) async {
    final paths =
        await albumFilePaths(dbPath: dbPath, releaseMbid: releaseMbid);
    final tracks = await listTracks(dbPath: dbPath, releaseMbid: releaseMbid);

    final items = _buildItems(paths, tracks, albumTitle);
    await _applyQueue(items, paths, index);
    await audioHandler.player.seek(Duration.zero, index: index);
    await audioHandler.play();
  }

  // -------------------------------------------------------------------------
  // Internal helpers
  // -------------------------------------------------------------------------

  List<MediaItem> _buildItems(
    List<String> paths,
    List<Track> tracks,
    String albumTitle,
  ) {
    return [
      for (var i = 0; i < paths.length; i++)
        MediaItem(
          id: paths[i],
          title: tracks[i].title,
          artist: tracks[i].artist,
          album: albumTitle,
          duration: tracks[i].lengthMs == null
              ? null
              : Duration(milliseconds: tracks[i].lengthMs!.toInt()),
          extras: {'trackId': tracks[i].id},
        ),
    ];
  }

  Future<void> _applyQueue(
    List<MediaItem> items,
    List<String> paths,
    int initialIndex,
  ) async {
    _currentItems = items;
    audioHandler.queue.add(items);
    await queueController.setQueue(paths, initialIndex: initialIndex);

    // Seed the mediaItem stream for the initial track.
    if (items.isNotEmpty) {
      audioHandler.mediaItem
          .add(items[initialIndex.clamp(0, items.length - 1)]);
    }
  }

  void _subscribeIndex() {
    audioHandler.player.currentIndexStream.listen((i) {
      if (i == null || i >= _currentItems.length) return;

      final item = _currentItems[i];

      // Emit the base item immediately so MPRIS has metadata right away.
      audioHandler.mediaItem.add(item);

      // Then enrich with cover art asynchronously.
      _enrichWithCoverArt(i, item);
    });
  }

  /// Fetches the cover art for [item] and, if found, re-emits the media item
  /// with [artUri] populated — but only if the current track hasn't changed
  /// in the meantime (race-guard via index + path comparison).
  Future<void> _enrichWithCoverArt(int expectedIndex, MediaItem item) async {
    final filePath = item.id;

    // Check in-memory cache first (avoids FFI round-trip for repeated plays).
    String? coverPath;
    if (_coverCache.containsKey(filePath)) {
      coverPath = _coverCache[filePath];
    } else {
      try {
        final cacheDir = await _resolveCacheDir();
        coverPath = await extractCover(filePath: filePath, cacheDir: cacheDir);
      } catch (_) {
        // Cover extraction failure must never break playback.
        coverPath = null;
      }
      _coverCache[filePath] = coverPath;
    }

    if (coverPath == null) return;

    // Race-guard: only apply if this track is still the current one.
    final currentIndex = audioHandler.player.currentIndex;
    if (currentIndex == null || currentIndex != expectedIndex) return;
    if (_currentItems.isEmpty || _currentItems[currentIndex].id != filePath) {
      return;
    }

    audioHandler.mediaItem.add(item.copyWith(artUri: Uri.file(coverPath)));
  }

  /// Returns (and lazily creates) the application cache directory path.
  Future<String> _resolveCacheDir() {
    _cacheDirFuture ??= getApplicationCacheDirectory().then((d) => d.path);
    return _cacheDirFuture!;
  }

  // -------------------------------------------------------------------------
  // Play tracking
  // -------------------------------------------------------------------------

  void _subscribePlayTracking() {
    // Watch for track changes to reset the per-track recorded flag.
    audioHandler.player.currentIndexStream.listen((i) {
      if (i != _trackedIndex) {
        _trackedIndex = i;
        _recordedForCurrentTrack = false;
      }
    });

    // Watch position to check the 50% / 4-minute threshold.
    _positionSub = audioHandler.player.positionStream.listen((_) {
      _checkAndRecord();
    });

    // Watch for track completion.
    _playerStateSub = audioHandler.player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _checkAndRecord(forceRecord: true);
      }
    });
  }

  void _checkAndRecord({bool forceRecord = false}) {
    if (_recordedForCurrentTrack) return;

    final index = audioHandler.player.currentIndex;
    if (index == null || index >= _currentItems.length) return;

    final item = _currentItems[index];
    final trackId = item.extras?['trackId'];
    if (trackId == null) return;

    if (forceRecord) {
      _doRecord(trackId);
      return;
    }

    final position = audioHandler.player.position;
    final duration = audioHandler.player.duration;

    // 4-minute threshold.
    if (position >= const Duration(minutes: 4)) {
      _doRecord(trackId);
      return;
    }

    // 50% threshold.
    if (duration != null &&
        duration > Duration.zero &&
        position.inMilliseconds >= duration.inMilliseconds / 2) {
      _doRecord(trackId);
      return;
    }
  }

  void _doRecord(dynamic trackId) {
    _recordedForCurrentTrack = true;
    final playedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    recordPlay(
      dbPath: dbPath,
      trackId: trackId,
      playedAt: playedAt,
    );
  }

  void dispose() {
    _positionSub?.cancel();
    _playerStateSub?.cancel();
  }
}

// ---------------------------------------------------------------------------
// Riverpod provider
// ---------------------------------------------------------------------------

final playbackControllerProvider = Provider<PlaybackController>((ref) {
  throw UnimplementedError(
    'playbackControllerProvider must be overridden in ProviderScope',
  );
});

/// Holds the currently selected [Album] object so the track column can
/// retrieve the album title and releaseMbid when starting playback.
class SelectedAlbumObject extends Notifier<Album?> {
  @override
  Album? build() => null;

  void select(Album? album) => state = album;
}

final selectedAlbumObjectProvider =
    NotifierProvider<SelectedAlbumObject, Album?>(SelectedAlbumObject.new);
