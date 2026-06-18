import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';
import 'package:olivier/widgets/bilingual_text.dart';

/// Normalize a `ReorderableListView` pre-removal `newIndex` to the canonical
/// destination index. When using the legacy `onReorder` callback, Flutter
/// reports `newIndex` as the pre-removal slot; for a downward move that is one
/// past the final resting slot, so we subtract one. Upward moves are
/// unaffected. (`onReorderItem` already delivers the post-removal index and
/// does not need this function.)
int normalizeReorder(int oldIndex, int newIndex) =>
    newIndex > oldIndex ? newIndex - 1 : newIndex;

/// Collapsible queue panel between the browse split and the now-playing bar.
/// Collapsed: shows the count + up-next header with Shuffle/Empty/Shuffle-all
/// placeholder controls and an expand caret. Expanded: the header plus a
/// ReorderableListView of queued tracks (bilingual titles, drag handle, ×
/// remove, tap-to-play, current-track highlight).
class QueuePanel extends ConsumerStatefulWidget {
  const QueuePanel({super.key});

  @override
  ConsumerState<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends ConsumerState<QueuePanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final queueAsync = ref.watch(queueProvider);
    final view = queueAsync.value ?? QueueView.empty;
    final count = view.tracks.length;
    final upNext = _upNext(view);
    final theme = Theme.of(context);

    final header = Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
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
            // Empty — clears the entire queue.
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Empty queue',
              onPressed: () => ref.read(queueControllerProvider).clear(),
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

    if (!_expanded) return header;

    return Column(
      children: [
        header,
        Expanded(child: _expandedList(context, view)),
      ],
    );
  }

  Widget _expandedList(BuildContext context, QueueView view) {
    final leads = ref.watch(languageLeadsProvider);
    final controller = ref.read(queueControllerProvider);
    final scheme = Theme.of(context).colorScheme;

    return ReorderableListView.builder(
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
