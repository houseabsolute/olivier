import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/bilingual_text.dart';

class TrackColumn extends ConsumerWidget {
  const TrackColumn({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracksAsync = ref.watch(tracksProvider);
    return tracksAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (tracks) => _TrackList(tracks: tracks),
    );
  }
}

class _TrackList extends ConsumerWidget {
  const _TrackList({required this.tracks});

  final List<Track> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (tracks.isEmpty) {
      return const Center(child: Text('Select an album'));
    }

    // We need the currently selected album to get the releaseMbid and title.
    final releaseMbid = ref.watch(selectedAlbumProvider);
    final albumObj = ref.watch(selectedAlbumObjectProvider);
    final albumTitle = albumObj?.title ?? '';
    final leads = ref.watch(languageLeadsProvider);

    return ListView.builder(
      itemCount: tracks.length,
      itemExtent: 48,
      scrollCacheExtent: const ScrollCacheExtent.pixels(600),
      itemBuilder: (context, index) {
        final track = tracks[index];
        return InkWell(
          key: ValueKey(track.id),
          onTap: () {
            if (releaseMbid == null) return;
            ref.read(playbackControllerProvider).playTrack(
                  releaseMbid,
                  albumTitle,
                  index,
                );
          },
          child: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: BilingualText(
                    original: track.title,
                    translit: track.titleTranslit,
                    translate: track.titleTranslate,
                    leads: leads,
                    prefix: '${track.position}. ',
                  ),
                ),
                Text(
                  _formatLength(track.lengthMs),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatLength(BigInt? lengthMs) {
    if (lengthMs == null) return '';
    final totalSeconds = (lengthMs ~/ BigInt.from(1000)).toInt();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
