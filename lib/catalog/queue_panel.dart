import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/state/layout_settings.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';
import 'package:olivier/widgets/album_cover.dart';
import 'package:olivier/widgets/bilingual_text.dart';

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

/// Collapsible queue panel between the browse split and the now-playing bar.
/// Collapsed: shows the count + up-next header with fully-wired Shuffle,
/// Empty, and Shuffle-all controls plus an expand caret. Expanded: the header
/// plus a ReorderableListView of queued tracks (bilingual titles, drag handle,
/// × remove, tap-to-play, current-track highlight).
class QueuePanel extends ConsumerStatefulWidget {
  const QueuePanel({super.key});

  @override
  ConsumerState<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends ConsumerState<QueuePanel> {
  bool _expanded = false;
  double? _queueHeight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final s = await ref.read(layoutSettingsProvider.future);
        if (mounted) setState(() => _queueHeight = s.queueHeight);
      } catch (_) {
        // Fall back to the default; provider may be unavailable in some tests.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            if (nowPlaying != null) ...[
              PathCover(
                filePath: nowPlaying.path,
                size: 36,
              ),
              const SizedBox(width: 8),
            ],
            const Icon(Icons.queue_music, size: 20),
            const SizedBox(width: 8),
            Text('Queue · $count tracks', style: theme.textTheme.bodyMedium),
            if (upNext != null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '· up next: $upNext',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ] else
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
                  onPressed: () =>
                      ref.read(queueControllerProvider).setShuffle(!shuffled),
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
                _expanded ? Icons.expand_more : Icons.expand_less,
              ),
              tooltip: _expanded ? 'Collapse queue' : 'Expand queue',
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
          ],
        ),
      ),
    );

    final panel = _expanded
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              header,
              _expandedList(context, view),
            ],
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

    final maxH = MediaQuery.sizeOf(context).height * 0.6;
    final height =
        (_queueHeight ?? defaultQueueHeight).clamp(minQueueHeight, maxH);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.resizeRow,
          child: GestureDetector(
            key: const ValueKey('queue-resize-handle'),
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) {
              final max = MediaQuery.sizeOf(context).height * 0.6;
              setState(() {
                _queueHeight =
                    ((_queueHeight ?? defaultQueueHeight) - d.delta.dy)
                        .clamp(minQueueHeight, max);
              });
            },
            onVerticalDragEnd: (_) {
              ref.read(setSettingFnProvider)(
                layoutQueueHeightKey,
                (_queueHeight ?? defaultQueueHeight).toStringAsFixed(0),
              );
            },
            child: Container(
              height: 8,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: Container(
                width: 36,
                height: 3,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          height: height,
          child: ReorderableListView.builder(
            shrinkWrap: true,
            itemCount: view.tracks.length,
            // onReorderItem delivers the post-removal destination index directly
            // (unlike the deprecated onReorder which required normalizeReorder).
            onReorderItem: (oldIndex, newIndex) {
              controller.reorder(oldIndex, newIndex);
            },
            itemBuilder: (context, i) {
              final t = view.tracks[i];
              final selected = i == view.currentIndex;
              return Material(
                key: ValueKey('${t.path}#$i'),
                color: selected ? scheme.primaryContainer : Colors.transparent,
                child: InkWell(
                  onTap: () => controller.playAt(i),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: [
                        ReorderableDragStartListener(
                          index: i,
                          child: const Icon(Icons.drag_handle),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: BilingualText(
                            original: t.title,
                            translit: t.titleTranslit,
                            translate: t.titleTranslate,
                            leads: leads,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Remove from queue',
                          onPressed: () => controller.removeAt(i),
                        ),
                      ],
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
