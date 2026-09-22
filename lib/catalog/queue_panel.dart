import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/list_selection.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';
import 'package:olivier/state/queue_view.dart';
import 'package:olivier/widgets/album_cover.dart';
import 'package:olivier/widgets/bilingual_text.dart';
import 'package:olivier/widgets/context_menu.dart';
import 'package:olivier/widgets/queue_swipe_target.dart';
import 'package:olivier/widgets/info_dialog.dart';
import 'package:olivier/widgets/track_meta.dart';

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
// Wide enough for a 5-digit order number (a shuffle-entire-library queue can
// run into the ten-thousands) without wrapping the tight number cell.
const double _queueNumberColWidth = 48;
// The track's own number on its album (disc-prefixed on a multi-disc release,
// e.g. "2-05"), so it fits a two-digit disc and a two-digit position.
const double _queueTrackNoColWidth = 40;
const double _queueColGap = 8;
const double _queueRemoveColWidth = 40;
const int _queueTitleFlex = 3;
const int _queueArtistFlex = 2;
const int _queueAlbumFlex = 2;

/// Fixed per-row height for the expanded queue list, fed to the
/// `ReorderableListView.builder`'s `itemExtent` so Flutter can compute scroll
/// offsets in O(1). Without it, flinging/dragging to the bottom of a huge queue
/// (e.g. "Shuffle entire library" enqueues thousands of tracks) forces every row
/// to be laid out to resolve the scroll extent — an O(n) burst that hangs the UI
/// thread until it finishes. Reserves a 2-line bilingual row like the browse
/// columns' `_trackRowBase` (42) plus this row's `vertical: 4` padding (8px);
/// `bilingualRowExtent` scales it for the OS text size. See track_column.dart.
const double _queueRowBase = 50;

/// Below this panel width the fixed ~228px Length/Added/Played block leaves too
/// little room for the title/artist/album columns and the row would overflow,
/// so the meta columns drop out (in both the header and the rows) instead.
const double _queueMetaMinWidth = 608;

/// Below this panel width the collapsed header switches to a compact layout: the
/// now-playing thumbnail is dropped and the count text flexes so it ellipsizes
/// rather than forcing the row wider than the panel. The four controls stay
/// fixed-width, so at extreme widths (below ~250px, well under any realistic
/// window — no minimum window size is enforced) the row can still overflow.
const double _queueHeaderCompactWidth = 520;

/// The track's number on its own album, for the queue row's `#` column:
/// `disc-position` on a multi-disc release (e.g. `2-05`), otherwise just the
/// position. Empty for an entry whose path has left the catalog (no numbers to
/// show) — the same case that leaves `trackId` null.
String queueTrackNumber(QueueTrack t) {
  final position = t.position;
  if (position == null) return '';
  final disc = t.disc ?? 1;
  return disc > 1 ? '$disc-$position' : '$position';
}

/// Lays out one expanded-queue row — or the column header — with identical
/// geometry so the header labels align with the cells beneath them. [lead]
/// fills the drag-handle column, [trailing] the remove-button column. [meta]
/// (and its leading gap) is omitted when [showMeta] is false.
Widget _queueRowLayout({
  required Widget lead,
  required Widget number,
  required Widget trackNo,
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
      SizedBox(width: _queueNumberColWidth, child: number),
      const SizedBox(width: _queueColGap),
      SizedBox(width: _queueTrackNoColWidth, child: trackNo),
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
        number: const SizedBox.shrink(),
        trackNo: Text('#', textAlign: TextAlign.end, style: style),
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
/// Collapsed: shows an Empty control at the far left, then the count + up-next
/// header with Shuffle and Shuffle-all controls plus an expand caret. Expanded: the header
/// plus a column header and a ReorderableListView of queued tracks (bilingual
/// title, separate artist/album columns, drag handle, × remove,
/// current-track highlight).
class QueuePanel extends ConsumerStatefulWidget {
  const QueuePanel({super.key});

  @override
  ConsumerState<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends ConsumerState<QueuePanel> {
  final ScrollController _queueScrollController = ScrollController();

  @override
  void dispose() {
    _queueScrollController.dispose();
    super.dispose();
  }

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
    // Nothing is current once the queue has run out (view.ended), so the
    // header drops the now-playing thumbnail too.
    final currentIndex = view.ended ? null : view.currentIndex;
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
                // Empty — clears the entire queue. Disabled when already empty.
                // Kept at the far left, away from the other controls, so it's
                // hard to hit by accident.
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Empty queue',
                  onPressed: count == 0
                      ? null
                      : () => ref.read(queueControllerProvider).clear(),
                ),
                const SizedBox(width: 8),
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
                // The compact layout flexes it to ellipsize instead of overflowing
                // when narrow; expanded also flexes because the extra history
                // toggle button otherwise overflows the header at mid widths.
                if (compact || expanded)
                  Flexible(child: countText)
                else
                  countText,
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
                // Show / hide already-played tracks (expanded view only).
                if (expanded)
                  Consumer(
                    builder: (context, ref, _) {
                      final showPlayed = ref.watch(showPlayedProvider);
                      return IconButton(
                        tooltip: showPlayed
                            ? 'Hide played tracks'
                            : 'Show played tracks',
                        isSelected: showPlayed,
                        icon: const Icon(Icons.history),
                        onPressed: () =>
                            ref.read(showPlayedProvider.notifier).toggle(),
                      );
                    },
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

    // The header is also a swipe handle. The now-playing bar is one too, but it
    // sits against the bottom of the screen where Android's gesture-navigation
    // zone swallows downward drags before Flutter sees them — the header has
    // room, so this is the reliable way to swipe the queue closed.
    final swipeableHeader = QueueSwipeTarget(child: header);
    final panel = expanded
        ? Column(
            children: [
              swipeableHeader,
              Expanded(child: _expandedList(context, view)),
            ],
          )
        : swipeableHeader;

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
    final showPlayed = ref.watch(showPlayedProvider);
    // Queue rows are keyed by canonical index; the selection resets on every
    // structural change, which is exactly when those indices are renumbered.
    final selection = SelectionBinding(
      ref: ref,
      provider: queueSelectionProvider,
      rowKeys: [for (var i = 0; i < view.tracks.length; i++) '$i'],
      selection: ref.watch(queueSelectionProvider),
      singular: 'track',
    );
    final start = queueVisibleStart(
      showPlayed: showPlayed,
      currentIndex: view.currentIndex,
      trackCount: view.tracks.length,
      ended: view.ended,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final showMeta = constraints.maxWidth >= _queueMetaMinWidth;
        return Column(
          children: [
            _QueueColumnHeader(showMeta: showMeta),
            const Divider(height: 1),
            Expanded(
              child: Scrollbar(
                controller: _queueScrollController,
                thumbVisibility: true,
                child: ReorderableListView.builder(
                  scrollController: _queueScrollController,
                  // Fixed row height so scroll offsets are O(1) — otherwise a
                  // huge (shuffle-all) queue hangs the UI when scrolled to the
                  // bottom. Matches the browse columns' bilingualRowExtent use.
                  itemExtent: bilingualRowExtent(context, _queueRowBase),
                  // Each row supplies its own drag handle in the lead column, so
                  // suppress the SDK's default handle — on desktop it overlays a
                  // second handle on top of the × button and steals its taps.
                  buildDefaultDragHandles: false,
                  itemCount: view.tracks.length - start,
                  // onReorderItem delivers the post-removal destination index
                  // directly (unlike the deprecated onReorder which required
                  // normalizeReorder).
                  onReorderItem: (oldIndex, newIndex) {
                    controller.reorder(start + oldIndex, start + newIndex);
                  },
                  itemBuilder: (context, j) {
                    final i = start + j; // canonical index in the full queue
                    final t = view.tracks[i];
                    final playing = i == view.currentIndex && !view.ended;
                    final picked = selection.contains('$i');
                    final muted = Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant);
                    final year = t.originalYear ?? t.reissueYear ?? '';
                    final albumLabel =
                        year.isEmpty ? t.album : '${t.album} ($year)';
                    return RowContextMenu(
                      key: ValueKey('${t.path}#$i'),
                      entity: QueueEntityRef.track(t.trackId ?? 0),
                      onInfo: (_) => showInfoDialog(
                        context,
                        title: 'Track',
                        fields: queueTrackInfoFields(t),
                      ),
                      onOpenSelection: () => selection.openMenu('$i'),
                      onRemoveFromQueue: (_) => controller.removeAtAll(
                        [
                          for (final key in selection.selectedKeys)
                            int.parse(key)
                        ],
                      ),
                      child: Material(
                        // A row picked for a bulk action takes the selection
                        // colour; the now-playing tint shows through on every
                        // other row.
                        color: picked
                            ? scheme.primaryContainer
                            : playing
                                ? scheme.tertiaryContainer
                                : Colors.transparent,
                        child: InkWell(
                          onTap: () => selection.tap('$i'),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            child: _queueRowLayout(
                              lead: ReorderableDragStartListener(
                                index: j,
                                child: const Icon(Icons.drag_handle),
                              ),
                              number: Text(
                                '${i + 1}',
                                textAlign: TextAlign.end,
                                style: muted,
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                              ),
                              trackNo: Text(
                                queueTrackNumber(t),
                                textAlign: TextAlign.end,
                                style: muted,
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                              ),
                              title: BilingualText(
                                original: t.title,
                                translit: t.titleTranslit,
                                translate: t.titleTranslate,
                                leads: leads,
                              ),
                              artist: BilingualText(
                                original: t.albumArtistOriginal ??
                                    t.albumArtist ??
                                    '',
                                translit: t.albumArtistReading,
                                translate: null,
                                leads: leads,
                                primaryStyle: muted,
                              ),
                              album: Text(
                                albumLabel,
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
                      ),
                    );
                  },
                ),
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
    if (view.tracks.isEmpty || view.ended) return null;
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
