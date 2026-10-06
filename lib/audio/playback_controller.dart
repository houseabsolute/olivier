import 'dart:async';
import 'dart:developer' as developer;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
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

/// What to do with the player after a track fails to play.
enum PlaybackErrorAction { skipToNext, stop }

/// The user-facing notice + recovery action for a failed track.
@immutable
class PlaybackErrorOutcome {
  const PlaybackErrorOutcome({required this.message, required this.action});
  final String message;
  final PlaybackErrorAction action;
}

/// Builds the notice + recovery action for a track that failed to play. Pure
/// (no player, no Flutter) so it is unit-testable. [detail] is the message from
/// the player's `PlayerException` (mpv's error text), which may be null/empty.
PlaybackErrorOutcome resolvePlaybackError({
  required String title,
  required String? detail,
  required bool hasNext,
}) {
  final base = 'Couldn\'t play "$title"';
  return PlaybackErrorOutcome(
    message: (detail == null || detail.isEmpty) ? base : '$base: $detail',
    action: hasNext ? PlaybackErrorAction.skipToNext : PlaybackErrorAction.stop,
  );
}

class PlaybackController {
  PlaybackController({
    required this.audioHandler,
    required this.queueController,
    required this.dbPath,
    TracksForPathsFn? tracksForPathsFn,
    this.onPlaybackIssue,
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

  /// Surfaces a user-facing playback issue (e.g. a track that failed to play).
  /// Null in tests; wired to the app's ErrorReporter in main().
  final void Function(String message)? onPlaybackIssue;

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
  // Player index of the last track we already ran error recovery for, so the
  // per-frame repeat of a decode error only triggers one skip. Reset on track
  // change (see _subscribePlayTracking).
  int? _lastErrorIndex;
  bool _recordedForCurrentTrack = false;
  StreamSubscription<int?>? _indexSub;
  StreamSubscription<int?>? _trackSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<bool>? _playingSub;
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
    // just_audio's currentIndexStream re-emits on every playback event, not only
    // when the index changes. Without distinct() the same mediaItem is re-added
    // dozens of times a second, which makes the MPRIS layer emit a Metadata
    // PropertiesChanged for each one and pegs the compositor.
    _indexSub = audioHandler.player.currentIndexStream.distinct().listen((i) {
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
    // Watch for track changes to reset the per-track recorded flag and keep the
    // persisted playhead's track fresh as playback advances.
    _trackSub = audioHandler.player.currentIndexStream.listen(onTrackChanged);

    // Persist the playhead whenever playback pauses (captures the exact offset).
    _playingSub =
        audioHandler.player.playingStream.distinct().listen(onPlayingChanged);

    // Watch position to check the 50% / 4-minute threshold.
    _positionSub = audioHandler.player.positionStream.listen((_) {
      _checkAndRecord();
    });

    // Watch for track completion.
    _playerStateSub = audioHandler.player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _checkAndRecord(forceRecord: true);
        // End of the whole play order (just_audio only completes once the last
        // source finishes). Tell the queue so the view stops presenting the
        // finished track as current — the player's index stays put otherwise.
        queueController.markEnded();
      }
    });
  }

  /// Handles a player index change: reset per-track play-tracking state and,
  /// for a real (non-null) index, persist the playhead so the saved track stays
  /// current as playback advances. The index stream emits null transiently, so
  /// the null-gate is what prevents clobbering a good snapshot with index 0.
  ///
  /// Returns a future for test determinism; the stream subscription fires it
  /// unawaited, so in production the save runs fire-and-forget.
  @visibleForTesting
  Future<void> onTrackChanged(int? i) async {
    if (i != _trackedIndex) {
      _trackedIndex = i;
      _recordedForCurrentTrack = false;
      // New current track — allow one error recovery for it.
      _lastErrorIndex = null;
      if (i != null) await queueController.savePlayhead();
    }
  }

  /// Persists the playhead when playback stops driving (pause or end), so the
  /// exact offset is saved. No-op on the play edge. Returns a future for test
  /// determinism; fired unawaited by the stream subscription in production.
  @visibleForTesting
  Future<void> onPlayingChanged(bool playing) async {
    if (!playing) await queueController.savePlayhead();
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

  /// Playback errors (e.g. a corrupt/undecodable file, or a queued file deleted
  /// or on an unmounted drive) surface on `errorStream` as `PlayerException`s.
  /// Log them, tell the user, and recover so playback never silently wedges.
  void _subscribeErrors() {
    _errorSub = audioHandler.player.errorStream.listen((e) {
      developer.log(
        'playback error: ${e.message}',
        name: 'olivier.player',
        error: e,
      );
      _recoverFromError(e);
    });
  }

  /// A track failed to play. Surface the error and move on: skip to the next
  /// track, or stop if this is the last one. mpv re-emits the decode error per
  /// bad frame, so `_lastErrorIndex` limits us to one recovery per track.
  void _recoverFromError(PlayerException e) {
    final player = audioHandler.player;
    final idx = player.currentIndex;
    if (idx != null && idx == _lastErrorIndex) return;
    _lastErrorIndex = idx;

    final title = audioHandler.mediaItem.value?.title ?? 'this track';
    final outcome = resolvePlaybackError(
      title: title,
      detail: e.message,
      hasNext: player.hasNext,
    );
    onPlaybackIssue?.call(outcome.message);
    if (outcome.action == PlaybackErrorAction.skipToNext) {
      audioHandler.skipToNext();
    } else {
      audioHandler.stop();
    }
  }

  void dispose() {
    queueController.revision.removeListener(_onQueueRevision);
    _indexSub?.cancel();
    _trackSub?.cancel();
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    _playingSub?.cancel();
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
