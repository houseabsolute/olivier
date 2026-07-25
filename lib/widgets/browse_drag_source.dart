import 'package:flutter/material.dart';
import 'package:olivier/audio/queue_entity.dart';

/// Makes a browse row a drag source — but only where the drop can land.
///
/// The sole drop target for these drags is the queue panel
/// (`QueuePanelDropTarget`). In the narrow layout the queue is a separate
/// screen, so a drag has nowhere to go; the row passes [enabled] false and
/// spends the long press on its context menu instead, which is otherwise
/// right-click-only and unreachable by touch.
class BrowseDragSource extends StatelessWidget {
  const BrowseDragSource({
    super.key,
    required this.enabled,
    required this.entity,
    required this.label,
    required this.child,
  });

  final bool enabled;
  final QueueEntityRef entity;

  /// What the drag feedback chip reads.
  final String label;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return LongPressDraggable<QueueEntityRef>(
      data: entity,
      feedback: Material(
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(label),
        ),
      ),
      child: child,
    );
  }
}
