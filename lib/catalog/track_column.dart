import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/catalog/catalog_mutation.dart';
import 'package:olivier/playlists/add_to_playlist_dialog.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/capabilities.dart';
import 'package:olivier/state/list_selection.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/bilingual_text.dart';
import 'package:olivier/widgets/browse_drag_source.dart';
import 'package:olivier/widgets/context_menu.dart';
import 'package:olivier/widgets/info_dialog.dart';
import 'package:olivier/widgets/title_override_dialog.dart';
import 'package:olivier/widgets/track_meta.dart';

const double _trackNumWidth = 32;
const double _trackNumGap = 8;

/// Narrower than this and the track meta columns are dropped.
const double _trackMetaMinWidth = 480;

// Track rows are tighter than the artist/album columns (base 48): the two-line
// bilingual content needs ~36px, so 42 packs the rows closer together.
const double _trackRowBase = 42;

/// Append every selected track, in list order. The selection always contains
/// the row the menu was opened on, so this covers the single-row case too.
Future<void> enqueueSelectedTracks(WidgetRef ref, List<int> trackIds) async {
  final paths = await resolveEntitiesPaths(
    [for (final id in trackIds) QueueEntityRef.track(id)],
    ref.read(entityPathFnsProvider),
  );
  if (paths.isEmpty) return;
  await ref.read(queueControllerProvider).append(paths);
}

class TrackColumn extends ConsumerWidget {
  const TrackColumn({super.key, this.narrow = false});

  /// One-level-at-a-time layout: no queue panel on screen, so rows drop
  /// drag-to-queue and use long press for their context menu instead.
  final bool narrow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracksAsync = ref.watch(tracksProvider);
    return tracksAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (tracks) => _TrackList(narrow: narrow, tracks: tracks),
    );
  }
}

class _TrackList extends ConsumerStatefulWidget {
  const _TrackList({required this.tracks, required this.narrow});
  final bool narrow;

  final List<Track> tracks;

  @override
  ConsumerState<_TrackList> createState() => _TrackListState();
}

class _TrackListState extends ConsumerState<_TrackList> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToSelected(int? selected) {
    if (selected == null) return;
    final index = widget.tracks.indexWhere((t) => t.id == selected);
    if (index < 0) return;
    final extent = bilingualRowExtent(context, _trackRowBase);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      final rowTop = index * extent;
      // Already fully visible: leave it. Only an off-screen row (e.g. a search
      // hit) scrolls in — ordinary in-view clicks must not yank the list.
      if (rowTop >= pos.pixels &&
          rowTop + extent <= pos.pixels + pos.viewportDimension) {
        return;
      }
      _scroll.jumpTo(rowTop.clamp(0.0, pos.maxScrollExtent));
    });
  }

  @override
  Widget build(BuildContext context) {
    final tracks = widget.tracks;
    if (tracks.isEmpty) {
      return const Center(child: Text('Select an album'));
    }

    final leads = ref.watch(languageLeadsProvider);
    // A synced-catalog device must not edit what the desktop owns.
    final canModify = ref.watch(canModifyCatalogProvider);
    final selectedTrack = ref.watch(selectedTrackProvider);
    // Track rows key their selection by id, as a string like every other list.
    final selection = SelectionBinding(
      ref: ref,
      provider: trackSelectionProvider,
      rowKeys: [for (final t in tracks) '${t.id}'],
      selection: ref.watch(trackSelectionProvider),
      singular: 'track',
    );
    List<int> selectedIds() =>
        [for (final key in selection.selectedKeys) int.parse(key)];

    ref.listen<int?>(
        selectedTrackProvider, (_, next) => _scrollToSelected(next));
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _scrollToSelected(selectedTrack));

    return LayoutBuilder(builder: (context, constraints) {
      // Below this the length/added/played block crowds out the title, so it is
      // dropped from both the header and the rows — the same treatment the
      // queue panel gives its own meta columns. Keyed on this column's width,
      // not the window's, so a pane dragged narrow benefits too.
      final showMeta = constraints.maxWidth >= _trackMetaMinWidth;
      return Column(
        children: [
          _TrackListHeader(showMeta: showMeta),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemCount: tracks.length,
              itemExtent: bilingualRowExtent(context, _trackRowBase),
              scrollCacheExtent: const ScrollCacheExtent.pixels(600),
              itemBuilder: (context, index) {
                final track = tracks[index];
                final trackId = track.id;
                final isSelected =
                    selectedTrack == trackId || selection.contains('$trackId');
                final entity = QueueEntityRef.track(trackId);
                final recordingMbid = track.recordingMbid;
                return BrowseDragSource(
                  enabled: !widget.narrow,
                  entity: entity,
                  label: track.title,
                  child: RowContextMenu(
                    longPressToOpen: widget.narrow,
                    entity: entity,
                    onOpenSelection: () => selection.openMenu('$trackId'),
                    onAddToQueue: (_) =>
                        enqueueSelectedTracks(ref, selectedIds()),
                    onAddToPlaylist: (entity) =>
                        showAddToPlaylistDialog(context, ref, entity),
                    onInfo: (_) => showInfoDialog(context,
                        title: 'Track', fields: trackInfoFields(track)),
                    onReadTags: !canModify
                        ? null
                        : (_) => runCatalogMutation(
                              context,
                              ref,
                              action: () =>
                                  ref.read(rereadTrackTagsFnProvider)(track.id),
                              clearSelection: () => ref
                                  .read(selectedTrackProvider.notifier)
                                  .clear(),
                              successMessage: 'Tags re-read',
                              failureMessage: 'Failed to re-read tags',
                            ),
                    onSetReading: (recordingMbid == null || !canModify)
                        ? null
                        : (_) async {
                            final current = await ref.read(
                                trackTitleOverrideFnProvider)(recordingMbid);
                            if (!context.mounted) return;
                            await showTitleOverrideDialog(
                              context,
                              label: track.title,
                              current: current,
                              onSubmit: (t, tr) =>
                                  ref.read(setTrackTitleOverrideFnProvider)(
                                      recordingMbid, t, tr),
                              onSaved: () {
                                ref
                                    .read(queueControllerProvider)
                                    .refreshMetadata();
                                ref.invalidate(tracksProvider);
                              },
                            );
                          },
                    onRemove: !canModify
                        ? null
                        : (_) {
                            final ids = selectedIds();
                            final what = ids.length == 1
                                ? '"${track.title}"'
                                : '${ids.length} tracks';
                            runCatalogMutation(
                              context,
                              ref,
                              action: () async {
                                final remove = ref.read(removeTrackFnProvider);
                                for (final id in ids) {
                                  await remove(id);
                                }
                              },
                              clearSelection: () {
                                ref
                                    .read(selectedTrackProvider.notifier)
                                    .clear();
                                selection.clear();
                              },
                              successMessage: 'Removed $what',
                              failureMessage: 'Failed to remove $what',
                              reconcileQueue: true,
                            );
                          },
                    child: InkWell(
                      key: ValueKey(track.id),
                      onTap: () {
                        // Modified clicks only edit the selection.
                        if (!selection.tap('$trackId')) return;
                        ref
                            .read(selectedTrackProvider.notifier)
                            .select(trackId);
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
                            if (showMeta)
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
    });
  }
}

class _TrackListHeader extends StatelessWidget {
  const _TrackListHeader({required this.showMeta});

  /// Whether there is room for the length/added/played columns.
  final bool showMeta;

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
          if (showMeta) const TrackMetaHeader(),
        ],
      ),
    );
  }
}
