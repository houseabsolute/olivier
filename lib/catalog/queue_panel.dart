import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/state/queue_provider.dart';

/// Collapsible queue panel between the browse split and the now-playing bar.
/// This slice renders only the collapsed header (count + up-next); the expanded
/// reorderable list and the Shuffle/Empty/Shuffle-all controls land in later
/// slices.
class QueuePanel extends ConsumerWidget {
  const QueuePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueAsync = ref.watch(queueProvider);
    final view = queueAsync.value ?? QueueView.empty;
    final count = view.tracks.length;

    final upNext = _upNext(view);
    final theme = Theme.of(context);

    return Material(
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
            // Expand caret — wired to expand/collapse in slice 3.
            IconButton(
              icon: const Icon(Icons.expand_less),
              tooltip: 'Expand queue',
              onPressed: null,
            ),
          ],
        ),
      ),
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
