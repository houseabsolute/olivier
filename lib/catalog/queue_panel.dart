import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';
import 'package:olivier/widgets/album_cover.dart';
import 'package:olivier/widgets/bilingual_text.dart';
import 'package:olivier/widgets/context_menu.dart';
import 'package:olivier/widgets/info_dialog.dart';
import 'package:olivier/widgets/track_meta.dart';

/// Whether the queue panel is expanded to fill the browse area. Lifted out of
/// the panel so BrowserPage can hide the browse panes while it's expanded.
class QueueExpanded extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
}

final queueExpandedProvider =
    NotifierProvider<QueueExpanded, bool>(QueueExpanded.new);

/// Provider that exposes the [ShuffleAllTarget] the "Shuffle entire library"
/// control calls. Defaults to the canonical queue controller; tests override
/// with a fake.
final shuffleAllTargetProvider = Provider<ShuffleAllTarget>((ref) {
  return ref.watch(queueControllerProvider);
});

/// Resolves all library paths, optionally shows a confirm dialog when the queue
/// is non-empty, then calls [ShuffleAllTarget.replaceLibraryShuffled].
Future<void> shuffleEntireLibrary(BuildContext context, WidgetRef ref) async {
  final paths = await ref.read(libraryPathsFnProvider)();
  if (paths.isEmpty) return;

  final queueIsEmpty = ref.read(queueProvider).value?.tracks.isEmpty ?? true;
  if (!queueIsEmpty) {
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Shuffle entire library?'),
        content: Text(
          'This replaces the current queue with ${paths.length} tracks '
          'and shuffles playback.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Shuffle'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
  }

  await ref.read(shuffleAllTargetProvider).replaceLibraryShuffled(paths);
}

// Column geometry for the expanded-queue rows. The drag-handle and remove
// columns are fixed-width so the header labels line up with the data cells
// below them; the title/artist/album columns flex to share the rest.
const double _queueDragColWidth = 24;
const double _queueColGap = 8;
const double _queueRemoveColWidth = 40;
const int _queueTitleFlex = 3;
const int _queueArtistFlex = 2;
const int _queueAlbumFlex = 2;

/// Below this panel width the fixed ~228px Length/Added/Played block leaves too
/// little room for the title/artist/album columns and the row would overflow,
/// so the meta columns drop out (in both the header and the rows) instead.
const double _queueMetaMinWidth = 560;

/// Below this panel width the collapsed header switches to a compact layout: the
/// now-playing thumbnail is dropped and the count text flexes so it ellipsizes
/// rather than forcing the row wider than the panel. The four controls stay
/// fixed-width, so at extreme widths (below ~250px, well under any realistic
/// window — no minimum window size is enforced) the row can still overflow.
const double _queueHeaderCompactWidth = 520;

/// Lays out one expanded-queue row — or the column header — with identical
/// geometry so the header labels align with the cells beneath them. [lead]
/// fills the drag-handle column, [trailing] the remove-button column. [meta]
/// (and its leading gap) is omitted when [showMeta] is false.
Widget _queueRowLayout({
  required Widget lead,
  required Widget title,
  required Widget artist,
  required Widget album,
  required Widget meta,
  required Widget trailing,
  required bool showMeta,
}) {
  return Row(
    children: [
      SizedBox(width: _queueDragColWidth, child: lead),
      const SizedBox(width: _queueColGap),
      Expanded(flex: _queueTitleFlex, child: title),
      const SizedBox(width: _queueColGap),
      Expanded(flex: _queueArtistFlex, child: artist),
      const SizedBox(width: _queueColGap),
      Expanded(flex: _queueAlbumFlex, child: album),
      if (showMeta) ...[
        const SizedBox(width: _queueColGap),
        meta,
      ],
      const SizedBox(width: 4),
      SizedBox(width: _queueRemoveColWidth, child: trailing),
    ],
  );
}

/// Column-title header for the expanded queue, aligned to [_queueRowLayout].
class _QueueColumnHeader extends StatelessWidget {
  const _QueueColumnHeader({required this.showMeta});

  final bool showMeta;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: _queueRowLayout(
        lead: const SizedBox.shrink(),
        title: Text('Title', style: style),
        artist: Text('Artist', style: style),
        album: Text('Album', style: style),
        meta: const TrackMetaHeader(),
        showMeta: showMeta,
        trailing: const SizedBox.shrink(),
      ),
    );
  }
}

/// Collapsible queue panel between the browse split and the now-playing bar.
/// Collapsed: shows the count + up-next header with fully-wired Shuffle,
/// Empty, and Shuffle-all controls plus an expand caret. Expanded: the header
/// plus a column header and a ReorderableListView of queued tracks (bilingual
/// title, separate artist/album columns, drag handle, × remove,
/// current-track highlight).
class QueuePanel extends ConsumerStatefulWidget {
  const QueuePanel({super.key});

  @override
  ConsumerState<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends ConsumerState<QueuePanel> {
  @override
  Widget build(BuildContext context) {
    final expanded = ref.watch(queueExpandedProvider);
    final queueAsync = ref.watch(queueProvider);
    final view = queueAsync.value ?? QueueView.empty;
    final count = view.tracks.length;
    final upNext = _upNext(view);
    final theme = Theme.of(context);

    // Bounds-guard the now-playing index: the cheap index-update path in
    // queue_provider can momentarily pair a fresh currentIndex with stale
    // (shorter) tracks — e.g. right after appending an album, before _resolve()
    // repopulates tracks. Indexing without the range check threw a RangeError
    // during build, flashing Flutter's red error screen for a frame.
    final currentIndex = view.currentIndex;
    final nowPlaying = (currentIndex != null &&
            currentIndex >= 0 &&
            currentIndex < view.tracks.length)
        ? view.tracks[currentIndex]
        : null;

    final header = Material(
      color: theme.colorScheme.surfaceContainerHighest,
      // The controls and the count text are non-compressible; below a threshold
      // drop the now-playing thumbnail and let the count/up-next text ellipsize
      // so the row degrades instead of overflowing when the panel is narrow.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < _queueHeaderCompactWidth;
          final countText = Text(
            'Queue · $count tracks',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          );
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                if (nowPlaying != null && !compact) ...[
                  PathCover(
                    filePath: nowPlaying.path,
                    size: 36,
                  ),
                  const SizedBox(width: 8),
                ],
                const Icon(Icons.queue_music, size: 20),
                const SizedBox(width: 8),
                // Plain (full width) when there's room, so the count never
                // truncates while empty space sits in the up-next / Spacer cell.
                // Only the compact layout flexes it so it can ellipsize instead
                // of overflowing when the panel is genuinely narrow.
                if (compact) Flexible(child: countText) else countText,
                if (upNext != null)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        '· up next: $upNext',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  )
                else
                  const Spacer(),
                // Shuffle toggle — flips shuffle on/off, active state driven by
                // QueueView.shuffled (rebuilt when revision bumps).
                Consumer(
                  builder: (context, ref, _) {
                    final view = ref.watch(queueProvider).value;
                    final shuffled = view?.shuffled ?? false;
                    return IconButton(
                      tooltip: 'Shuffle',
                      isSelected: shuffled,
                      icon: const Icon(Icons.shuffle),
                      selectedIcon: const Icon(Icons.shuffle_on),
                      onPressed: () => ref
                          .read(queueControllerProvider)
                          .setShuffle(!shuffled),
                    );
                  },
                ),
                // Shuffle entire library — replaces the queue and starts shuffled.
                IconButton(
                  icon: const Icon(Icons.shuffle_on_outlined),
                  tooltip: 'Shuffle entire library',
                  onPressed: () => shuffleEntireLibrary(context, ref),
                ),
                // Empty — clears the entire queue. Disabled when already empty.
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Empty queue',
                  onPressed: count == 0
                      ? null
                      : () => ref.read(queueControllerProvider).clear(),
                ),
                // Expand / collapse caret.
                IconButton(
                  icon: Icon(
                    expanded ? Icons.expand_more : Icons.expand_less,
                  ),
                  tooltip: expanded ? 'Collapse queue' : 'Expand queue',
                  onPressed: () =>
                      ref.read(queueExpandedProvider.notifier).toggle(),
                ),
              ],
            ),
          );
        },
      ),
    );

    final panel = expanded
        ? Column(
            children: [header, Expanded(child: _expandedList(context, view))],
          )
        : header;

    return QueuePanelDropTarget(
      onEntityDropped: (entity) async {
        final paths = await resolveEntityPaths(
          entity,
          ref.read(entityPathFnsProvider),
        );
        if (paths.isEmpty) return;
        await ref.read(queueControllerProvider).append(paths);
      },
      child: panel,
    );
  }

  Widget _expandedList(BuildContext context, QueueView view) {
    final leads = ref.watch(languageLeadsProvider);
    final controller = ref.read(queueControllerProvider);
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final showMeta = constraints.maxWidth >= _queueMetaMinWidth;
        return Column(
          children: [
            _QueueColumnHeader(showMeta: showMeta),
            const Divider(height: 1),
            Expanded(
              child: ReorderableListView.builder(
                // Each row supplies its own drag handle in the lead column, so
                // suppress the SDK's default handle — on desktop it overlays a
                // second handle on top of the × button and steals its taps.
                buildDefaultDragHandles: false,
                itemCount: view.tracks.length,
                // onReorderItem delivers the post-removal destination index
                // directly (unlike the deprecated onReorder which required
                // normalizeReorder).
                onReorderItem: (oldIndex, newIndex) {
                  controller.reorder(oldIndex, newIndex);
                },
                itemBuilder: (context, i) {
                  final t = view.tracks[i];
                  final selected = i == view.currentIndex;
                  final muted = Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant);
                  return RowContextMenu(
                    key: ValueKey('${t.path}#$i'),
                    entity: QueueEntityRef.track(t.trackId ?? 0),
                    onInfo: (_) => showInfoDialog(
                      context,
                      title: 'Track',
                      fields: queueTrackInfoFields(t),
                    ),
                    child: Material(
                      color: selected
                          ? scheme.primaryContainer
                          : Colors.transparent,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        child: _queueRowLayout(
                          lead: ReorderableDragStartListener(
                            index: i,
                            child: const Icon(Icons.drag_handle),
                          ),
                          title: BilingualText(
                            original: t.title,
                            translit: t.titleTranslit,
                            translate: t.titleTranslate,
                            leads: leads,
                          ),
                          artist: BilingualText(
                            original:
                                t.albumArtistOriginal ?? t.albumArtist ?? '',
                            translit: t.albumArtistReading,
                            translate: null,
                            leads: leads,
                            primaryStyle: muted,
                          ),
                          album: Text(
                            t.album,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: muted,
                          ),
                          meta: TrackMeta(
                            lengthMs: t.lengthMs,
                            addedAt: t.addedAt,
                            lastPlayed: t.lastPlayed,
                          ),
                          showMeta: showMeta,
                          trailing: IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 40, minHeight: 40),
                            iconSize: 20,
                            icon: const Icon(Icons.close),
                            tooltip: 'Remove from queue',
                            onPressed: () => controller.removeAt(i),
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
      },
    );
  }

  /// The title of the entry that plays after the current one (or the first entry
  /// when nothing is current yet); null when the queue is empty or at its end.
  String? _upNext(QueueView view) {
    if (view.tracks.isEmpty) return null;
    final current = view.currentIndex;
    final nextIndex = current == null ? 0 : current + 1;
    if (nextIndex >= view.tracks.length) return null;
    return view.tracks[nextIndex].title;
  }
}

/// Wraps the queue panel so a dragged browse entity dropped onto it is resolved
/// and appended. Used around both the collapsed header and the expanded list.
class QueuePanelDropTarget extends StatelessWidget {
  const QueuePanelDropTarget({
    super.key,
    required this.onEntityDropped,
    required this.child,
  });

  final ValueChanged<QueueEntityRef> onEntityDropped;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DragTarget<QueueEntityRef>(
      onAcceptWithDetails: (d) => onEntityDropped(d.data),
      builder: (context, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        return Container(
          decoration: hovering
              ? BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                )
              : null,
          child: child,
        );
      },
    );
  }
}
