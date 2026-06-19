import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/bilingual_text.dart';
import 'package:olivier/widgets/context_menu.dart';

Future<void> _enqueue(WidgetRef ref, QueueEntityRef entity) async {
  final paths = await resolveEntityPaths(
    entity,
    ref.read(entityPathFnsProvider),
  );
  if (paths.isEmpty) return;
  await ref.read(queueControllerProvider).append(paths);
}

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

    final leads = ref.watch(languageLeadsProvider);
    final selectedTrack = ref.watch(selectedTrackProvider);

    return ListView.builder(
      itemCount: tracks.length,
      itemExtent: bilingualRowExtent(context, 48),
      scrollCacheExtent: const ScrollCacheExtent.pixels(600),
      itemBuilder: (context, index) {
        final track = tracks[index];
        final trackId = track.id;
        final isSelected = selectedTrack == trackId;
        final entity = QueueEntityRef.track(trackId);
        return LongPressDraggable<QueueEntityRef>(
          data: entity,
          feedback: Material(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(track.title),
            ),
          ),
          child: RowContextMenu(
            entity: entity,
            onAddToQueue: (e) => _enqueue(ref, e),
            child: InkWell(
              key: ValueKey(track.id),
              onTap: () =>
                  ref.read(selectedTrackProvider.notifier).select(trackId),
              onDoubleTap: () async {
                final path = await ref.read(trackPathFnProvider)(trackId);
                if (path == null) return;
                await ref.read(queueControllerProvider).append([path]);
              },
              child: Container(
                color: isSelected
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null,
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
