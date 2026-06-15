import 'dart:developer' as developer;
import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:olivier/src/rust/api/queue.dart';
import 'package:olivier/src/rust/db.dart';

/// Holds the canonical ordered list and rebuilds the player's sources on
/// shuffle (engine shuffle is ignored by the media_kit backend on Linux).
class QueueController {
  QueueController(this.player, {required this.dbPath});
  final AudioPlayer player;
  final String dbPath;

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
  }

  Future<void> setShuffle(bool on) async {
    _shuffled = on;
    await _rebuild(0);
    await _persist();
  }

  Future<void> _rebuild(
    int initialIndex, {
    Duration initialPosition = Duration.zero,
  }) async {
    final order =
        _shuffled ? (List.of(_orderedPaths)..shuffle()) : _orderedPaths;
    _playOrder = List.of(order);
    await player.setAudioSources(
      [for (final p in order) AudioSource.file(p)],
      initialIndex:
          order.isEmpty ? null : initialIndex.clamp(0, order.length - 1),
      initialPosition: initialPosition,
    );
  }

  Future<void> _persist() async {
    final snapshot = QueueSnapshot(
      paths: List.of(_orderedPaths),
      currentIndex: player.currentIndex ?? 0,
      positionMs: BigInt.from(player.position.inMilliseconds),
      shuffle: _shuffled,
    );
    await saveQueue(dbPath: dbPath, snapshot: snapshot);
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
}
