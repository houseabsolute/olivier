import 'package:flutter/material.dart';

/// Collapsed-only queue panel shell.
///
/// This slice renders the static header (label + disabled controls + expand
/// caret) only; the live count, expansion, and the Shuffle/Empty/Shuffle-all
/// actions are wired in later slices. All controls are intentionally disabled
/// (`onPressed: null`) until then.
class QueuePanel extends StatelessWidget {
  const QueuePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            // Placeholder count — real count arrives with the queue view.
            Text('Queue · 0', style: theme.textTheme.titleSmall),
            const Spacer(),
            const IconButton(
              icon: Icon(Icons.shuffle),
              tooltip: 'Shuffle',
              onPressed: null,
            ),
            const IconButton(
              icon: Icon(Icons.delete_outline),
              tooltip: 'Empty queue',
              onPressed: null,
            ),
            const IconButton(
              icon: Icon(Icons.shuffle_on_outlined),
              tooltip: 'Shuffle entire library',
              onPressed: null,
            ),
            const IconButton(
              icon: Icon(Icons.expand_less),
              tooltip: 'Expand queue',
              onPressed: null,
            ),
          ],
        ),
      ),
    );
  }
}
