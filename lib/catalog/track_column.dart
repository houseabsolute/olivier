import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/bilingual_text.dart';
import 'package:olivier/widgets/context_menu.dart';
import 'package:olivier/widgets/info_dialog.dart';
import 'package:olivier/widgets/track_meta.dart';

const double _trackNumWidth = 32;
const double _trackNumGap = 8;

// Track rows are tighter than the artist/album columns (base 48): the two-line
// bilingual content needs ~36px, so 42 packs the rows closer together.
const double _trackRowBase = 42;

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

    return Column(
      children: [
        const _TrackListHeader(),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: tracks.length,
            itemExtent: bilingualRowExtent(context, _trackRowBase),
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
                  onInfo: (_) => showInfoDialog(context,
                      title: 'Track', fields: trackInfoFields(track)),
                  onReadTags: (_) async {
                    final messenger = ScaffoldMessenger.of(context);
                    await ref.read(rereadTrackTagsFnProvider)(track.id);
                    ref.invalidate(artistsProvider);
                    ref.invalidate(albumsProvider);
                    ref.invalidate(tracksProvider);
                    ref.read(selectedTrackProvider.notifier).clear();
                    messenger
                      ..clearSnackBars()
                      ..showSnackBar(
                          const SnackBar(content: Text('Tags re-read')));
                  },
                  child: InkWell(
                    key: ValueKey(track.id),
                    onTap: () => ref
                        .read(selectedTrackProvider.notifier)
                        .select(trackId),
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
                          SizedBox(
                            width: _trackNumWidth,
                            child: Text(
                              '${track.position}',
                              textAlign: TextAlign.right,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ),
                          const SizedBox(width: _trackNumGap),
                          Expanded(
                            child: BilingualText(
                              original: track.title,
                              translit: track.titleTranslit,
                              translate: track.titleTranslate,
                              leads: leads,
                            ),
                          ),
                          TrackMeta(
                            lengthMs: track.lengthMs,
                            addedAt: track.addedAt,
                            lastPlayed: track.lastPlayed,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TrackListHeader extends StatelessWidget {
  const _TrackListHeader();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: _trackNumWidth,
            child: Text('#', textAlign: TextAlign.right, style: style),
          ),
          const SizedBox(width: _trackNumGap),
          Expanded(child: Text('Title', style: style)),
          const TrackMetaHeader(),
        ],
      ),
    );
  }
}
