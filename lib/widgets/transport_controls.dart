import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:olivier/audio/audio_handler.dart';

/// The transport buttons' input state, derived from the player. A pure value
/// type so [resolveTransport] (and its tests) need no real player.
@immutable
class TransportState {
  const TransportState({
    required this.hasCurrent,
    required this.hasNext,
    required this.playing,
    required this.isLoading,
  });

  /// A track is loaded (the player has a current source).
  final bool hasCurrent;

  /// There is a track after the current one.
  final bool hasNext;

  /// The player is currently playing (vs paused).
  final bool playing;

  /// The player is loading/buffering (show a spinner, not an icon).
  final bool isLoading;
}

/// The rendered state of the three transport buttons.
@immutable
class TransportButtons {
  const TransportButtons({
    required this.prevEnabled,
    required this.playEnabled,
    required this.nextEnabled,
    required this.showSpinner,
    required this.showPauseIcon,
  });

  final bool prevEnabled;
  final bool playEnabled;
  final bool nextEnabled;

  /// Show the loading spinner in the play/pause slot instead of an icon.
  final bool showSpinner;

  /// The play/pause icon is "pause" (true) rather than "play" (false).
  final bool showPauseIcon;
}

/// Pure mapping from player state to button state. Prev (restart the current
/// track) and play/pause need a loaded track; next needs a following track.
TransportButtons resolveTransport(TransportState s) => TransportButtons(
      prevEnabled: s.hasCurrent,
      playEnabled: s.hasCurrent,
      nextEnabled: s.hasNext,
      showSpinner: s.isLoading,
      showPauseIcon: s.playing,
    );

/// Previous / play-pause / next buttons rendered from a [TransportButtons]. A
/// disabled button passes `onPressed: null` so Material greys it out. Pure (no
/// player) so it is widget-testable.
class TransportControlsView extends StatelessWidget {
  const TransportControlsView({
    super.key,
    required this.buttons,
    required this.onPrev,
    required this.onPlayPause,
    required this.onNext,
  });

  final TransportButtons buttons;
  final VoidCallback onPrev;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.skip_previous),
          tooltip: 'Restart track',
          onPressed: buttons.prevEnabled ? onPrev : null,
        ),
        if (buttons.showSpinner)
          const Padding(
            padding: EdgeInsets.all(8),
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else
          IconButton(
            icon: Icon(buttons.showPauseIcon ? Icons.pause : Icons.play_arrow),
            tooltip: buttons.showPauseIcon ? 'Pause' : 'Play',
            onPressed: buttons.playEnabled ? onPlayPause : null,
          ),
        IconButton(
          icon: const Icon(Icons.skip_next),
          tooltip: 'Next',
          onPressed: buttons.nextEnabled ? onNext : null,
        ),
      ],
    );
  }
}

/// Previous / play-pause / next, driven by the audio handler's player state.
/// Extracted from the now-playing bar so it can live in the top app bar.
class TransportControls extends StatelessWidget {
  const TransportControls({super.key, required this.audioHandler});

  final OlivierAudioHandler audioHandler;

  @override
  Widget build(BuildContext context) {
    final player = audioHandler.player;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.skip_previous),
          tooltip: 'Previous',
          onPressed: () => audioHandler.skipToPrevious(),
        ),
        StreamBuilder<PlayerState>(
          stream: player.playerStateStream,
          builder: (context, snap) {
            final state = snap.data;
            final playing = state?.playing ?? false;
            final processingState =
                state?.processingState ?? ProcessingState.idle;
            final isLoading = processingState == ProcessingState.loading ||
                processingState == ProcessingState.buffering;
            if (isLoading) {
              return const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            }
            return IconButton(
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              tooltip: playing ? 'Pause' : 'Play',
              onPressed: () =>
                  playing ? audioHandler.pause() : audioHandler.play(),
            );
          },
        ),
        IconButton(
          icon: const Icon(Icons.skip_next),
          tooltip: 'Next',
          onPressed: () => audioHandler.skipToNext(),
        ),
      ],
    );
  }
}
