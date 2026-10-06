import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

/// Clamp a relative seek target to the playable range. With no known duration
/// only the lower bound (zero) is applied.
Duration clampSeek(Duration position, Duration delta, Duration? duration) {
  final target = position + delta;
  if (target < Duration.zero) return Duration.zero;
  if (duration != null && target > duration) return duration;
  return target;
}

class OlivierAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final AudioPlayer player = AudioPlayer();

  /// Floor on how often a position-only state update reaches the platform.
  /// Just_audio emits a playback event on every position tick, and forwarding
  /// each one makes the MPRIS layer emit a `PropertiesChanged` per tick — GNOME
  /// Shell's MPRIS controller re-reads every one, which pegs the compositor.
  /// Real state changes (play/pause, buffering, track change) still go out at once.
  static const _minPositionUpdateInterval = Duration(seconds: 1);

  PlaybackState? _lastEmitted;
  DateTime? _lastEmit;

  OlivierAudioHandler() {
    player.playbackEventStream.map(_toState).listen(_emitPlaybackState);
  }

  void _emitPlaybackState(PlaybackState state) {
    final prev = _lastEmitted;
    final meaningful = prev == null ||
        state.playing != prev.playing ||
        state.processingState != prev.processingState ||
        state.queueIndex != prev.queueIndex ||
        state.speed != prev.speed;

    final now = DateTime.now();
    final tooSoon = _lastEmit != null &&
        now.difference(_lastEmit!) < _minPositionUpdateInterval;
    if (!meaningful && tooSoon) return;

    _lastEmitted = state;
    _lastEmit = now;
    playbackState.add(state);
  }

  @override
  Future<void> play() => player.play();
  @override
  Future<void> pause() => player.pause();

  /// Toggle between playing and paused — bound to the space bar.
  Future<void> togglePlayPause() => player.playing ? pause() : play();

  /// Set output volume (0.0–1.0).
  Future<void> setVolume(double v) => player.setVolume(v);

  @override
  Future<void> stop() => player.stop();
  @override
  Future<void> seek(Duration position) => player.seek(position);

  /// Seek relative to the current position, clamped to [0, duration].
  Future<void> seekBy(Duration delta) =>
      seek(clampSeek(player.position, delta, player.duration));
  @override
  Future<void> skipToNext() => player.seekToNext();
  @override
  Future<void> skipToPrevious() => player.seekToPrevious();

  PlaybackState _toState(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[player.processingState]!,
      playing: player.playing,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      speed: player.speed,
      queueIndex: event.currentIndex,
    );
  }
}
