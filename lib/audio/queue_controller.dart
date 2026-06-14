import 'package:just_audio/just_audio.dart';

/// Holds the canonical ordered list and rebuilds the player's sources on
/// shuffle (engine shuffle is ignored by the media_kit backend on Linux).
class QueueController {
  QueueController(this.player);
  final AudioPlayer player;

  List<String> _orderedPaths = [];
  bool _shuffled = false;

  Future<void> setQueue(List<String> paths, {int initialIndex = 0}) async {
    _orderedPaths = List.of(paths);
    _shuffled = false;
    await _rebuild(initialIndex);
  }

  Future<void> setShuffle(bool on) async {
    _shuffled = on;
    await _rebuild(0);
  }

  Future<void> _rebuild(int initialIndex) async {
    final order =
        _shuffled ? (List.of(_orderedPaths)..shuffle()) : _orderedPaths;
    await player.setAudioSources(
      [for (final p in order) AudioSource.file(p)],
      initialIndex:
          order.isEmpty ? null : initialIndex.clamp(0, order.length - 1),
      initialPosition: Duration.zero,
    );
  }
}
