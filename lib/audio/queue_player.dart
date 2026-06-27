import 'package:just_audio/just_audio.dart';

/// Narrow port over the just_audio [AudioPlayer] operations the queue mutators
/// need. Exists so the queue logic (path bookkeeping + persistence + the
/// incremental, playback-preserving source ops) can be unit-tested without a
/// real media_kit backend, which cannot run headless.
abstract class QueuePlayer {
  Future<void> addAudioSource(AudioSource source);
  Future<void> insertAudioSource(int index, AudioSource source);
  Future<void> removeAudioSourceAt(int index);
  Future<void> moveAudioSource(int from, int to);
  Future<void> setAudioSources(
    List<AudioSource> sources, {
    int? initialIndex,
    Duration initialPosition,
  });
  Future<void> seek(Duration position, {int? index});
  Future<void> play();

  /// Halt playback and deactivate the native player. Needed by `clear()`:
  /// just_audio's `setAudioSources([])` does NOT message the backend (its
  /// `load()` early-returns on an empty playlist), so it leaves the native
  /// media_kit player holding — and playing — the previous sources. `stop()`
  /// deactivates the platform so a later play()/rebuild starts clean.
  Future<void> stop();
  int? get currentIndex;
  Duration get position;
  Stream<int?> get currentIndexStream;
}

/// Adapts a real [AudioPlayer] to [QueuePlayer]; used in production.
class JustAudioQueuePlayer implements QueuePlayer {
  JustAudioQueuePlayer(this.player);
  final AudioPlayer player;

  @override
  Future<void> addAudioSource(AudioSource source) =>
      player.addAudioSource(source);

  @override
  Future<void> insertAudioSource(int index, AudioSource source) =>
      player.insertAudioSource(index, source);

  @override
  Future<void> removeAudioSourceAt(int index) =>
      player.removeAudioSourceAt(index);

  @override
  Future<void> moveAudioSource(int from, int to) =>
      player.moveAudioSource(from, to);

  @override
  Future<void> setAudioSources(
    List<AudioSource> sources, {
    int? initialIndex,
    Duration initialPosition = Duration.zero,
  }) =>
      player.setAudioSources(
        sources,
        initialIndex: initialIndex,
        initialPosition: initialPosition,
      );

  @override
  Future<void> seek(Duration position, {int? index}) =>
      player.seek(position, index: index);

  @override
  Future<void> play() => player.play();

  @override
  Future<void> stop() => player.stop();

  @override
  int? get currentIndex => player.currentIndex;

  @override
  Duration get position => player.position;

  @override
  Stream<int?> get currentIndexStream => player.currentIndexStream;
}
