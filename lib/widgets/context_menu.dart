import 'package:flutter/material.dart';
import 'package:olivier/audio/queue_entity.dart';

/// Wraps [child] so a right-click (secondary tap) opens a context menu, and
/// optionally a long press too — see [longPressToOpen]. The
/// optional [onAddToQueue]/[onInfo]/[onReadTags]/[onRefetch]/[onSetReading]/[onRemoveFromQueue]/[onRemove] entries appear
/// only when their callback is non-null, so each column shows the actions
/// appropriate to its entity.
///
/// In a list that supports multi-select, [onOpenSelection] folds this row into
/// the selection and reports how many rows the menu should speak for; the
/// bulk-capable entries then name the selection ("Add 3 albums to queue") and
/// the single-row-only ones (info, tags, readings) drop out. Handlers are still
/// called with this row's [entity] — a list acting on a selection reads it from
/// its own state, which [onOpenSelection] has just settled.
class RowContextMenu extends StatelessWidget {
  const RowContextMenu({
    super.key,
    required this.entity,
    this.onAddToQueue,
    this.onAddToPlaylist,
    this.onInfo,
    this.onReadTags,
    this.onRefetch,
    this.onSetReading,
    this.onRemoveFromQueue,
    this.onRemoveFromPlaylist,
    this.onRemove,
    this.onOpenSelection,
    this.longPressToOpen = false,
    required this.child,
  });

  final QueueEntityRef entity;
  final ValueChanged<QueueEntityRef>? onAddToQueue;
  final ValueChanged<QueueEntityRef>? onAddToPlaylist;
  final ValueChanged<QueueEntityRef>? onInfo;
  final ValueChanged<QueueEntityRef>? onReadTags;
  final ValueChanged<QueueEntityRef>? onRefetch;
  final ValueChanged<QueueEntityRef>? onSetReading;
  final ValueChanged<QueueEntityRef>? onRemoveFromQueue;
  final ValueChanged<QueueEntityRef>? onRemoveFromPlaylist;
  final ValueChanged<QueueEntityRef>? onRemove;

  /// Called just before the menu is built, so a multi-select list can settle
  /// its selection around the clicked row. Returns the noun phrase naming a
  /// multi-row selection ("3 tracks"), or null when the menu should address
  /// this row alone. Read at open time, not build time, so it sees the
  /// selection as it stands after the click.
  final String? Function()? onOpenSelection;

  /// Also open on long press. Off by default because the browse rows use long
  /// press for drag-to-queue; only layouts without a drop target on screen —
  /// the narrow one, where the queue is a separate screen — turn it on, and
  /// those drop the draggable so the two never compete for the gesture.
  final bool longPressToOpen;

  final Widget child;

  Future<void> _show(BuildContext context, Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    // Null → this row alone; otherwise the selection this menu speaks for.
    final many = onOpenSelection?.call();
    final single = many == null;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        if (onAddToQueue != null)
          PopupMenuItem<String>(
              value: 'add',
              child: Text(single ? 'Add to queue' : 'Add $many to queue')),
        if (onAddToPlaylist != null)
          PopupMenuItem<String>(
              value: 'playlist',
              child:
                  Text(single ? 'Add to playlist…' : 'Add $many to playlist…')),
        // The rest describe or edit one entity, so they only make sense — and
        // only appear — when the menu is speaking for a single row.
        if (single && onInfo != null)
          const PopupMenuItem<String>(value: 'info', child: Text('Info')),
        if (single && onReadTags != null)
          const PopupMenuItem<String>(
              value: 'reread', child: Text('Re-read tags')),
        if (single && onRefetch != null)
          const PopupMenuItem<String>(
              value: 'refetch', child: Text('Re-fetch from MusicBrainz')),
        if (single && onSetReading != null)
          const PopupMenuItem<String>(
              value: 'reading', child: Text('Set reading…')),
        if (onRemoveFromQueue != null)
          PopupMenuItem<String>(
              value: 'removeFromQueue',
              child: Text(
                  single ? 'Remove from queue' : 'Remove $many from queue')),
        if (onRemoveFromPlaylist != null)
          PopupMenuItem<String>(
              value: 'removeFromPlaylist',
              child: Text(single
                  ? 'Remove from playlist'
                  : 'Remove $many from playlist')),
        if (onRemove != null)
          PopupMenuItem<String>(
              value: 'remove',
              child: Text(single
                  ? 'Remove from library'
                  : 'Remove $many from library')),
      ],
    );
    switch (selected) {
      case 'add':
        onAddToQueue?.call(entity);
      case 'playlist':
        onAddToPlaylist?.call(entity);
      case 'info':
        onInfo?.call(entity);
      case 'reread':
        onReadTags?.call(entity);
      case 'refetch':
        onRefetch?.call(entity);
      case 'reading':
        onSetReading?.call(entity);
      case 'removeFromQueue':
        onRemoveFromQueue?.call(entity);
      case 'removeFromPlaylist':
        onRemoveFromPlaylist?.call(entity);
      case 'remove':
        onRemove?.call(entity);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (d) => _show(context, d.globalPosition),
      onLongPressStart:
          longPressToOpen ? (d) => _show(context, d.globalPosition) : null,
      child: child,
    );
  }
}
