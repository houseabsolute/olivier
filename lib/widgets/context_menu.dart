import 'package:flutter/material.dart';
import 'package:olivier/audio/queue_entity.dart';

/// Wraps [child] so a right-click (secondary tap) opens a context menu with an
/// "Add to queue" entry for [entity]. Other menu entries (re-read tags, info,
/// per-entity re-fetch) are separate backlog items that add to the same menu.
class AddToQueueMenu extends StatelessWidget {
  const AddToQueueMenu({
    super.key,
    required this.entity,
    required this.onAddToQueue,
    required this.child,
  });

  final QueueEntityRef entity;
  final ValueChanged<QueueEntityRef> onAddToQueue;
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
      items: const [
        PopupMenuItem<String>(
          value: 'add',
          child: Text('Add to queue'),
        ),
      ],
    );
    if (selected == 'add') onAddToQueue(entity);
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
