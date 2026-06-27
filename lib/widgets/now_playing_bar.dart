import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:olivier/audio/audio_handler.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/bilingual_text.dart';
import 'package:olivier/widgets/transport_controls.dart';
import 'package:rxdart/rxdart.dart';

class PositionData {
  const PositionData(this.position, this.bufferedPosition, this.duration);
  final Duration position;
  final Duration bufferedPosition;
  final Duration duration;
}

class NowPlayingBar extends ConsumerWidget {
  const NowPlayingBar({super.key, required this.audioHandler});

  final OlivierAudioHandler audioHandler;

  AudioPlayer get _player => audioHandler.player;

  Stream<PositionData> get _posStream =>
      Rx.combineLatest3<Duration, Duration, Duration?, PositionData>(
        _player.positionStream,
        _player.bufferedPositionStream,
        _player.durationStream,
        (p, b, d) => PositionData(p, b, d ?? Duration.zero),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final leads = ref.watch(languageLeadsProvider);
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      surfaceTintColor: Colors.transparent,
      child: SizedBox(
        // Grow the bar with the OS text size so the (up to) two-line bilingual
        // title plus the artist line never overflow at large accessibility scale.
        height: bilingualRowExtent(context, 80),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              // Title / artist.
              Expanded(
                flex: 2,
                child: StreamBuilder<MediaItem?>(
                  stream: audioHandler.mediaItem,
                  builder: (context, snap) {
                    final item = snap.data;
                    if (item == null) {
                      return const Text(
                        'Nothing playing',
                        overflow: TextOverflow.ellipsis,
                      );
                    }
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        BilingualText(
                          original: item.title,
                          translit: item.extras?['titleTranslit'] as String?,
                          translate: item.extras?['titleTranslate'] as String?,
                          leads: leads,
                          primaryStyle: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        if (item.artist != null)
                          BilingualText(
                            original: item.artist!,
                            translit: item.extras?['artistReading'] as String?,
                            translate: null,
                            leads: leads,
                            primaryStyle: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              TransportControls(audioHandler: audioHandler),
              const SizedBox(width: 8),
              // Seek slider + time labels.
              Expanded(
                flex: 3,
                child: StreamBuilder<PositionData>(
                  stream: _posStream,
                  builder: (context, snap) {
                    final pd = snap.data ??
                        const PositionData(
                          Duration.zero,
                          Duration.zero,
                          Duration.zero,
                        );
                    final maxMs = pd.duration.inMilliseconds
                        .toDouble()
                        .clamp(1.0, double.infinity);
                    final posMs =
                        pd.position.inMilliseconds.toDouble().clamp(0.0, maxMs);
                    return Row(
                      children: [
                        Text(_fmt(pd.position)),
                        Expanded(
                          child: Slider(
                            min: 0,
                            max: maxMs,
                            value: posMs,
                            onChanged: (v) =>
                                _player.seek(Duration(milliseconds: v.toInt())),
                          ),
                        ),
                        Text(_fmt(pd.duration)),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
