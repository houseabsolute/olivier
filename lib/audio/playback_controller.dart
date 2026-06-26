import 'dart:async';
import 'dart:developer' as developer;

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:olivier/audio/audio_handler.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/api/catalog.dart';
import 'package:olivier/src/rust/api/cover.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:path_provider/path_provider.dart';

/// Resolves catalog metadata for a list of file paths. Defaults to the real
/// `tracksForPaths` FFI; a test injects a fake so it can drive
/// [PlaybackController]'s now-playing sync without the Rust bridge.
typedef TracksForPathsFn = Future<List<QueueTrack>> Function(
    List<String> paths);

/// Builds the audio_service [MediaItem] list for a set of queue tracks.
///
/// Pure top-level function (no FFI, no I/O) so it is unit-testable host-VM and
/// shared by every now-playing rebuild path. Cover art is added later,
/// asynchronously, by [PlaybackController._enrichWithCoverArt]; this only maps
/// the catalog fields the player and MPRIS need up front.
List<MediaItem> mediaItemsForQueueTracks(List<QueueTrack> qts) {
  return [
    for (final qt in qts)
      MediaItem(
        id: qt.path,
        title: qt.title,
        artist: qt.albumArtistOriginal ?? qt.albumArtist,
        album: qt.album.isEmpty ? null : qt.album,
        duration: qt.lengthMs == null
            ? null
            : Duration(milliseconds: qt.lengthMs!.toInt()),
        extras: {
          if (qt.trackId != null) 'trackId': qt.trackId,
          'titleTranslit': qt.titleTranslit,
          'titleTranslate': qt.titleTranslate,
          'artistReading': qt.albumArtistReading,
        },
      ),
  ];
}

class PlaybackController {
  PlaybackController({
    required this.audioHandler,
    required this.queueController,
    required this.dbPath,
    TracksForPathsFn? tracksForPathsFn,
  }) : _tracksForPaths = tracksForPathsFn ??
            ((paths) => tracksForPaths(dbPath: dbPath, paths: paths)) {
    _subscribeIndex();
    _subscribePlayTracking();
    _subscribeErrors();
    // Follow the live queue: every queue mutation (append/playAt/removeAt/
    // reorder/clear/shuffle) bumps `revision`, after which we rebuild the
    // now-playing metadata from the player's actual order so the now-playing
    // bar, MPRIS, and play tracking stay in sync — not just after a restore.
    queueController.revision.addListener(_onQueueRevision);
  }

  final OlivierAudioHandler audioHandler;
  final QueueController queueController;
  final String dbPath;

  // FFI seam for resolving catalog metadata by path (injectable for tests).
  final TracksForPathsFn _tracksForPaths;

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
  StreamSubscription<PlayerException>? _errorSub;

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  /// Rebuild now-playing metadata for a queue restored from disk on startup.
  /// The queue controller has already rebuilt the player's sources; this seeds
  /// `_currentItems`, the audio_service queue, and the current media item (in
  /// the player's actual order) so the now-playing bar, MPRIS, and play tracking
  /// work for a restored session — not just after a fresh play. Shares the same
  /// path as live queue mutations via [_syncNowPlayingFromQueue].
  Future<void> restoreNowPlaying() => _syncNowPlayingFromQueue();

  // -------------------------------------------------------------------------
  // Live-queue sync
  // -------------------------------------------------------------------------

  // Serialises overlapping revision callbacks: each rebuild awaits the FFI, and
  // revisions can arrive faster than that, so we chain them to avoid emitting a
  // stale media item out of order.
  Future<void> _syncChain = Future<void>.value();

  void _onQueueRevision() {
    _syncChain = _syncChain
        .then((_) => _syncNowPlayingFromQueue())
        .catchError((Object e, StackTrace st) {
      developer.log(
        'now-playing sync failed',
        name: 'olivier.player',
        error: e,
        stackTrace: st,
      );
    });
  }

  /// Rebuild `_currentItems`, the audio_service queue, and the current media
  /// item from the queue's LIVE play order (the player's actual order, shuffled
  /// or canonical — NOT the displayed canonical order). Used by both startup
  /// restore and every live queue mutation.
  Future<void> _syncNowPlayingFromQueue() async {
    final order = queueController.playOrder;
    if (order.isEmpty) {
      _currentItems = [];
      audioHandler.queue.add(const []);
      // Queue emptied (cleared, or the last/only track removed) — clear the
      // now-playing item so the bottom bar resets instead of showing the
      // removed track (mediaItem is a BehaviorSubject that holds its last value).
      audioHandler.mediaItem.add(null);
      return;
    }

    final queueTracks = await _tracksForPaths(order);
    final items = mediaItemsForQueueTracks(queueTracks);

    _currentItems = items;
    audioHandler.queue.add(items);
    if (items.isEmpty) return;

    final i =
        (audioHandler.player.currentIndex ?? 0).clamp(0, items.length - 1);
    audioHandler.mediaItem.add(items[i]);
    _enrichWithCoverArt(i, items[i]);
  }

  // -------------------------------------------------------------------------
  // Internal helpers
  // -------------------------------------------------------------------------

  void _subscribeIndex() {
    audioHandler.player.currentIndexStream.listen((i) {
      // NOTE: clearing now-playing when the queue empties is handled by the
      // queue-revision path (_syncNowPlayingFromQueue's empty branch), NOT here:
      // this stream is the player's own index, which reports null transiently
      // (and always, headless) for reasons unrelated to an emptied queue, so
      // clearing on null here would race the revision sync and wipe a valid item.
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
        coverPath = await coverForPath(
            dbPath: dbPath, filePath: filePath, cacheDir: cacheDir);
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
    // PlatformInt64 is `int` on the native targets; a null/placeholder track
    // (a queued file no longer in the catalog) has none and is skipped.
    final trackId = item.extras?['trackId'];
    if (trackId is! int) return;

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

  void _doRecord(int trackId) {
    _recordedForCurrentTrack = true;
    final playedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    recordPlay(
      dbPath: dbPath,
      trackId: trackId,
      playedAt: playedAt,
    );
  }

  /// Log playback errors (e.g. a queued file that was deleted or whose drive is
  /// unmounted) instead of letting them surface as an unhandled exception, so a
  /// bad track is skipped/logged and the app keeps running.
  void _subscribeErrors() {
    // MPV / source-open failures (e.g. a queued file deleted mid-session, or a
    // drive that unmounts) surface on errorStream as PlayerExceptions, not as
    // stream errors on the event stream — log them so they don't go unhandled.
    _errorSub = audioHandler.player.errorStream.listen((e) {
      developer.log(
        'playback error: ${e.message}',
        name: 'olivier.player',
        error: e,
      );
    });
  }

  void dispose() {
    queueController.revision.removeListener(_onQueueRevision);
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    _errorSub?.cancel();
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

/// Exposes the [QueueController] held by the [PlaybackController] so queue
/// panels and enqueue menus can call its ops directly.
final queueControllerProvider = Provider<QueueController>(
  (ref) => ref.watch(playbackControllerProvider).queueController,
);

/// Holds the currently selected [Album] object so the track column can
/// retrieve the album title and releaseMbid when starting playback.
class SelectedAlbumObject extends Notifier<Album?> {
  @override
  Album? build() => null;

  void select(Album? album) => state = album;
}

final selectedAlbumObjectProvider =
    NotifierProvider<SelectedAlbumObject, Album?>(SelectedAlbumObject.new);
