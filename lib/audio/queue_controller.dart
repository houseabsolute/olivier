import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:olivier/audio/queue_player.dart';
import 'package:olivier/src/rust/api/queue.dart' as rust_queue;
import 'package:olivier/src/rust/db.dart';

/// Persists a [QueueSnapshot]. Defaults to the real `saveQueue` FFI; tests
/// inject a fake so they don't need to load the Rust cdylib.
typedef SaveQueueFn = Future<void> Function(QueueSnapshot snapshot);

/// The single method "Shuffle entire library" needs from the queue controller.
/// Narrowed to an interface so the action is unit-testable with a fake.
abstract interface class ShuffleAllTarget {
  Future<void> replaceLibraryShuffled(List<String> paths);
}

/// Holds the canonical ordered list and rebuilds the player's sources on
/// shuffle (engine shuffle is ignored by the media_kit backend on Linux).
class QueueController implements ShuffleAllTarget {
  QueueController(AudioPlayer player,
      {required this.dbPath, SaveQueueFn? saveQueue})
      : _player = JustAudioQueuePlayer(player),
        _saveQueue = saveQueue ??
            ((snap) => rust_queue.saveQueue(dbPath: dbPath, snapshot: snap));

  /// Test seam: inject a [QueuePlayer] (fake) directly.
  @visibleForTesting
  QueueController.withPlayer(this._player,
      {required this.dbPath, SaveQueueFn? saveQueue})
      : _saveQueue = saveQueue ??
            ((snap) => rust_queue.saveQueue(dbPath: dbPath, snapshot: snap));

  final QueuePlayer _player;
  final String dbPath;
  final SaveQueueFn _saveQueue;

  /// Bumped after every mutation so the queue view can rebuild.
  final ValueNotifier<int> revision = ValueNotifier(0);

  /// Re-resolve the now-playing/queue metadata without changing the queue
  /// order — used when an artist's reading override changes so the displayed
  /// album-artist (and its reading) refreshes in the queue panel, the
  /// now-playing bar, and MPRIS.
  void refreshMetadata() => revision.value++;

  List<String> _orderedPaths = [];
  // The actual order the player's sources are in (shuffled or canonical), so the
  // now-playing items can be built to line up 1:1 with the player by index.
  List<String> _playOrder = [];
  bool _shuffled = false;

  Future<void> setQueue(List<String> paths, {int initialIndex = 0}) async {
    _orderedPaths = List.of(paths);
    _shuffled = false;
    await _rebuild(initialIndex);
    await _persist();
    revision.value++;
  }

  Future<void> setShuffle(bool on) async {
    // Keep playing the same track from the same position across the toggle
    // (spec §3: shuffle randomizes order with the list "staying put", it does
    // NOT restart playback). Capture the canonical current track + position
    // BEFORE flipping `_shuffled`, then rebuild seeded on that canonical index.
    final cur = currentCanonicalIndex ?? 0;
    final pos = _player.position;
    _shuffled = on;
    await _rebuild(cur, initialPosition: pos);
    await _persist();
    revision.value++;
  }

  /// Append paths to the END of the queue without interrupting playback. Each
  /// path is added to the canonical order and mirrored to the player via the
  /// incremental `addAudioSource` op (no rebuild → current track keeps playing).
  /// When not shuffled, `_playOrder` stays equal to `_orderedPaths`; when
  /// shuffled, new paths join the tail of both (they were not part of the
  /// earlier shuffle, which is acceptable — a reshuffle is a deliberate reset).
  Future<void> append(List<String> paths) async {
    for (final path in paths) {
      _orderedPaths.add(path);
      _playOrder.add(path);
      await _player.addAudioSource(AudioSource.file(path));
    }
    await _persist();
    revision.value++;
  }

  /// Remove the entry at [index] in the DISPLAYED canonical order
  /// (_orderedPaths), keeping playback uninterrupted. When not shuffled the
  /// player source index equals the canonical index; when shuffled we translate
  /// through _playOrder. Occurrence-aware so duplicate paths are handled.
  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _orderedPaths.length) return;
    final playerIndex = _playerIndexForCanonical(index);
    final path = _orderedPaths.removeAt(index);
    if (playerIndex >= 0 && playerIndex < _playOrder.length) {
      _playOrder.removeAt(playerIndex);
      await _player.removeAudioSourceAt(playerIndex);
    }
    assert(path.isNotEmpty);
    await _persist();
    revision.value++;
  }

  /// Drop every queue entry whose path is in [paths] — e.g. tracks just removed
  /// from the library. Occurrence-aware (all copies go); mirrors each removal to
  /// the player (descending so source indices stay valid). If the
  /// currently-playing source is removed, just_audio advances to the next;
  /// emptying the queue stops playback. No-op for an empty set.
  Future<void> removePaths(Set<String> paths) async {
    if (paths.isEmpty) return;
    for (var i = _playOrder.length - 1; i >= 0; i--) {
      if (paths.contains(_playOrder[i])) {
        _playOrder.removeAt(i);
        await _player.removeAudioSourceAt(i);
      }
    }
    _orderedPaths.removeWhere((p) => paths.contains(p));
    await _persist();
    revision.value++;
  }

  /// Maps a canonical _orderedPaths index to the matching player source index in
  /// _playOrder, accounting for the same path appearing multiple times. Returns
  /// the same index when not shuffled (orders are in sync).
  int _playerIndexForCanonical(int index) {
    final path = _orderedPaths[index];
    var occurrence = 0;
    for (var i = 0; i < index; i++) {
      if (_orderedPaths[i] == path) occurrence++;
    }
    var seen = 0;
    for (var i = 0; i < _playOrder.length; i++) {
      if (_playOrder[i] == path) {
        if (seen == occurrence) return i;
        seen++;
      }
    }
    return index; // fallback: orders are in sync
  }

  /// Move the entry at [from] to [to] within the canonical order.
  Future<void> reorder(int from, int to) async {
    if (from < 0 || from >= _orderedPaths.length) return;
    final path = _orderedPaths.removeAt(from);
    final dest = to.clamp(0, _orderedPaths.length);
    _orderedPaths.insert(dest, path);
    if (!_shuffled) {
      _playOrder
        ..removeAt(from)
        ..insert(dest, path);
      await _player.moveAudioSource(from, dest);
    }
    // When shuffled, _playOrder is independent of the canonical order, so only
    // the canonical list + persistence change here (Slice 5 owns shuffle ops).
    await _persist();
    revision.value++;
  }

  /// Empty the whole queue and stop driving the player.
  ///
  /// Clearing the player's sources is the single source of truth: it drives
  /// `currentIndexStream` to null, which causes the existing
  /// `PlaybackController._subscribeIndex` guard (`if (i == null …) return`) to
  /// stop emitting a stale media item — so now-playing also clears without any
  /// extra teardown here.
  Future<void> clear() async {
    _orderedPaths = [];
    _playOrder = [];
    await _player.setAudioSources([]);
    await _persist();
    revision.value++;
  }

  /// The ONE queue-replacing action: replace the queue with [paths], turn
  /// shuffle on, and start playing. Used by "Shuffle entire library".
  @override
  Future<void> replaceLibraryShuffled(List<String> paths) async {
    await setQueue(paths);
    await setShuffle(true);
    // setShuffle now preserves the currently-playing canonical track (here that
    // is canonical-0). "Shuffle entire library" should instead START on a
    // random track, so jump to player-order 0 (a random track after the
    // shuffle) before playing.
    await _player.seek(Duration.zero, index: 0);
    await _player.play();
  }

  /// Rebuilds the player's sources from the canonical list. [canonicalIndex] is
  /// an index into `_orderedPaths` (the canonical/display order); it is
  /// translated to the matching position in the (possibly shuffled) player
  /// order before being handed to `setAudioSources(initialIndex:)`. When not
  /// shuffled `order == _orderedPaths`, so the translated index equals
  /// [canonicalIndex] and the not-shuffled behavior is unchanged.
  Future<void> _rebuild(
    int canonicalIndex, {
    Duration initialPosition = Duration.zero,
  }) async {
    final order =
        _shuffled ? (List.of(_orderedPaths)..shuffle()) : _orderedPaths;
    _playOrder = List.of(order);
    int? initialIndex;
    if (order.isNotEmpty) {
      final clampedCanonical = canonicalIndex.clamp(0, order.length - 1);
      final startPath = _orderedPaths[clampedCanonical];
      final translated = order.indexOf(startPath);
      initialIndex = (translated < 0 ? clampedCanonical : translated)
          .clamp(0, order.length - 1);
    }
    await _player.setAudioSources(
      [for (final p in order) AudioSource.file(p)],
      initialIndex: initialIndex,
      initialPosition: initialPosition,
    );
  }

  Future<void> _persist() async {
    final snapshot = QueueSnapshot(
      // currentIndex is CANONICAL (an index into `paths`), so it round-trips
      // correctly through restoreFromSnapshot even when shuffled — the saved
      // player-order index would not address the saved canonical paths.
      paths: List.of(_orderedPaths),
      currentIndex: currentCanonicalIndex ?? 0,
      positionMs: BigInt.from(_player.position.inMilliseconds),
      shuffle: _shuffled,
    );
    await _saveQueue(snapshot);
  }

  /// Restore a previously saved snapshot without re-persisting. Files that no
  /// longer exist on disk (e.g. a drive that isn't mounted, or a file deleted
  /// since last run) are dropped and logged so the player never tries to open
  /// them; the saved current track keeps pointing at the right song.
  Future<void> restoreFromSnapshot(QueueSnapshot snap) async {
    final kept = <String>[];
    var currentIndex = 0;
    for (var i = 0; i < snap.paths.length; i++) {
      if (await File(snap.paths[i]).exists()) {
        if (i <= snap.currentIndex) currentIndex = kept.length;
        kept.add(snap.paths[i]);
      } else {
        developer.log(
          'skipping missing queued file: ${snap.paths[i]}',
          name: 'olivier.queue',
        );
      }
    }
    if (kept.isEmpty) return;

    _orderedPaths = kept;
    _shuffled = snap.shuffle;
    // Seek back to the saved offset for the current track on restore.
    // (Throttled mid-track position write-back is deferred to Phase 3 — for
    // now position is only captured at structural changes, so it's typically 0.)
    await _rebuild(
      currentIndex.clamp(0, kept.length - 1),
      initialPosition: Duration(milliseconds: snap.positionMs.toInt()),
    );
  }

  List<String> get orderedPaths => List.unmodifiable(_orderedPaths);

  /// The current player source order (shuffled or canonical) — index-aligned
  /// with what the player is playing.
  List<String> get playOrder => List.unmodifiable(_playOrder);
  bool get shuffled => _shuffled;

  /// The player's current-source-index stream, surfaced so the queue view can
  /// recompute the canonical highlight when the track advances.
  ///
  /// Uses `.distinct()` as defense in depth: just_audio re-emits on every
  /// playback event (including during loading/buffering), not only on actual
  /// index changes. Filtering here prevents naive listeners from triggering
  /// unnecessary work.
  Stream<int?> get currentIndexStream => _player.currentIndexStream.distinct();

  /// Canonical index (into [orderedPaths]) of the entry the player is currently
  /// on. Equals `player.currentIndex` when not shuffled; when shuffled it maps
  /// the player's current source back through `_playOrder`. Null when empty.
  int? get currentCanonicalIndex {
    if (_orderedPaths.isEmpty) return null;
    final pi = _player.currentIndex ?? 0;
    if (pi < 0 || pi >= _playOrder.length) return null;
    // Occurrence-aware inverse of `_playerIndexForCanonical`: find which
    // occurrence (k) of this path the player is on, then return the canonical
    // index of the k-th occurrence in `_orderedPaths`. A naive `indexOf` would
    // map DUPLICATE paths to the wrong (first) canonical occurrence.
    final path = _playOrder[pi];
    var occurrence = 0;
    for (var i = 0; i < pi; i++) {
      if (_playOrder[i] == path) occurrence++;
    }
    var seen = 0;
    for (var i = 0; i < _orderedPaths.length; i++) {
      if (_orderedPaths[i] == path) {
        if (seen == occurrence) return i;
        seen++;
      }
    }
    return null;
  }

  /// Jump to and play the entry at canonical [index]. Translates the canonical
  /// index to the player's source index via _playOrder (identity when not
  /// shuffled, occurrence-aware for duplicates).
  Future<void> playAt(int index) async {
    if (index < 0 || index >= _orderedPaths.length) return;
    final playerIndex = _playerIndexForCanonical(index);
    await _player.seek(Duration.zero, index: playerIndex);
    await _player.play();
  }
}
