import 'package:flutter/material.dart';
import 'package:olivier/audio/queue_entity.dart';

/// Wraps [child] so a right-click (secondary tap) opens a context menu. The
/// optional [onAddToQueue]/[onInfo]/[onReadTags]/[onRefetch]/[onSetReading]/[onRemove] entries appear
/// only when their callback is non-null, so each column shows the actions
/// appropriate to its entity.
class RowContextMenu extends StatelessWidget {
  const RowContextMenu({
    super.key,
    required this.entity,
    this.onAddToQueue,
    this.onInfo,
    this.onReadTags,
    this.onRefetch,
    this.onSetReading,
    this.onRemove,
    required this.child,
  });

  final QueueEntityRef entity;
  final ValueChanged<QueueEntityRef>? onAddToQueue;
  final ValueChanged<QueueEntityRef>? onInfo;
  final ValueChanged<QueueEntityRef>? onReadTags;
  final ValueChanged<QueueEntityRef>? onRefetch;
  final ValueChanged<QueueEntityRef>? onSetReading;
  final ValueChanged<QueueEntityRef>? onRemove;
  final Widget child;

  Future<void> _show(BuildContext context, Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        if (onAddToQueue != null)
          const PopupMenuItem<String>(
              value: 'add', child: Text('Add to queue')),
        if (onInfo != null)
          const PopupMenuItem<String>(value: 'info', child: Text('Info')),
        if (onReadTags != null)
          const PopupMenuItem<String>(
              value: 'reread', child: Text('Re-read tags')),
        if (onRefetch != null)
          const PopupMenuItem<String>(
              value: 'refetch', child: Text('Re-fetch from MusicBrainz')),
        if (onSetReading != null)
          const PopupMenuItem<String>(
              value: 'reading', child: Text('Set reading…')),
        if (onRemove != null)
          const PopupMenuItem<String>(
              value: 'remove', child: Text('Remove from library')),
      ],
    );
    switch (selected) {
      case 'add':
        onAddToQueue?.call(entity);
      case 'info':
        onInfo?.call(entity);
      case 'reread':
        onReadTags?.call(entity);
      case 'refetch':
        onRefetch?.call(entity);
      case 'reading':
        onSetReading?.call(entity);
      case 'remove':
        onRemove?.call(entity);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (d) => _show(context, d.globalPosition),
      child: child,
    );
  }
}
