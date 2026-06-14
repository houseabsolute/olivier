import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

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

class _TrackList extends StatelessWidget {
  const _TrackList({required this.tracks});

  final List<Track> tracks;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return const Center(child: Text('Select an album'));
    }
    return ListView.builder(
      itemCount: tracks.length,
      itemExtent: 48,
      scrollCacheExtent: const ScrollCacheExtent.pixels(600),
      itemBuilder: (context, index) {
        final track = tracks[index];
        return Container(
          key: ValueKey(track.id),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: _RowLabel(
                  text: '${track.position}. ${track.title}',
                ),
              ),
              Text(
                _formatLength(track.lengthMs),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
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

class _RowLabel extends StatelessWidget {
  const _RowLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      overflow: TextOverflow.ellipsis,
    );
  }
}
