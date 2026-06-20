import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:olivier/audio/audio_handler.dart';

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
