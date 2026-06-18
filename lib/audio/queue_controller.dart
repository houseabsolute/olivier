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

/// Holds the canonical ordered list and rebuilds the player's sources on
/// shuffle (engine shuffle is ignored by the media_kit backend on Linux).
class QueueController {
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
    _shuffled = on;
    await _rebuild(0);
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

  /// Remove the entry at [index] in the DISPLAYED canonical order.
  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _orderedPaths.length) return;
    final path = _orderedPaths.removeAt(index);
    if (!_shuffled) {
      // Player order == canonical order, so the indices line up.
      _playOrder.removeAt(index);
      await _player.removeAudioSourceAt(index);
    } else {
      // Shuffled: find this path's position in the independent play order.
      // (Duplicate paths + shuffle edge cases are finished in Slice 5.)
      final playerIndex = _playOrder.indexOf(path);
      if (playerIndex >= 0) {
        _playOrder.removeAt(playerIndex);
        await _player.removeAudioSourceAt(playerIndex);
      }
    }
    await _persist();
    revision.value++;
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
  Future<void> clear() async {
    _orderedPaths = [];
    _playOrder = [];
    await _player.setAudioSources([]);
    await _persist();
    revision.value++;
  }

  Future<void> _rebuild(
    int initialIndex, {
    Duration initialPosition = Duration.zero,
  }) async {
    final order =
        _shuffled ? (List.of(_orderedPaths)..shuffle()) : _orderedPaths;
    _playOrder = List.of(order);
    await _player.setAudioSources(
      [for (final p in order) AudioSource.file(p)],
      initialIndex:
          order.isEmpty ? null : initialIndex.clamp(0, order.length - 1),
      initialPosition: initialPosition,
    );
  }

  Future<void> _persist() async {
    final snapshot = QueueSnapshot(
      paths: List.of(_orderedPaths),
      currentIndex: _player.currentIndex ?? 0,
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

  /// Canonical index (into [orderedPaths]) of the entry the player is currently
  /// on. Equals `player.currentIndex` when not shuffled; when shuffled it maps
  /// the player's current source back through `_playOrder`. Null when empty.
  int? get currentCanonicalIndex {
    if (_orderedPaths.isEmpty) return null;
    final pi = _player.currentIndex ?? 0;
    if (pi < 0 || pi >= _playOrder.length) return null;
    final idx = _orderedPaths.indexOf(_playOrder[pi]);
    return idx < 0 ? null : idx;
  }

  /// Jump to and play the entry at canonical [index].
  Future<void> playAt(int index) async {
    if (index < 0 || index >= _orderedPaths.length) return;
    final path = _orderedPaths[index];
    // Map canonical -> player index (== index when not shuffled).
    final playerIndex = _shuffled ? _playOrder.indexOf(path) : index;
    if (playerIndex < 0) return;
    await _player.seek(Duration.zero, index: playerIndex);
    await _player.play();
  }
}
