import 'package:flutter/material.dart';

/// A two-pane split with a draggable divider.
///
/// [ratio] (0..1) is the fraction of the available main-axis extent given to the
/// FIRST child; dragging the divider changes it and [onRatioSettled] fires at
/// drag-end so the parent can persist it.
///
/// The divider uses an OPAQUE gesture so it claims the drag exclusively. This is
/// the whole point of this widget: `multi_split_view`'s divider is translucent,
/// so its drag was shared with the scrollable browse columns behind it and lost
/// the gesture arena — the cursor changed but the boundary never moved. An
/// opaque handle (the same approach the queue resize handle already uses) wins
/// the arena and resizes reliably.
class ResizableSplit extends StatefulWidget {
  const ResizableSplit({
    super.key,
    required this.axis,
    required this.first,
    required this.second,
    required this.ratio,
    required this.onRatioSettled,
    this.minFirst = 80,
    this.minSecond = 80,
  });

  final Axis axis;
  final Widget first;
  final Widget second;

  /// Fraction (0..1) of the available extent given to [first].
  final double ratio;

  /// Minimum logical pixels for the first / second pane.
  final double minFirst;
  final double minSecond;

  /// Called at the end of a drag with the new ratio (for persistence).
  final ValueChanged<double> onRatioSettled;

  @override
  State<ResizableSplit> createState() => _ResizableSplitState();
}

class _ResizableSplitState extends State<ResizableSplit> {
  static const double _dividerThickness = 8;

  late double _ratio = widget.ratio;
  bool _hovering = false;

  @override
  void didUpdateWidget(ResizableSplit oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Adopt a newly-loaded persisted ratio from the parent (e.g. after the
    // async settings load reseeds it).
    if (oldWidget.ratio != widget.ratio) _ratio = widget.ratio;
  }

  void _drag(double delta, double avail) {
    if (avail <= 0) return;
    setState(() {
      final maxFirst = (avail - widget.minSecond).clamp(widget.minFirst, avail);
      final newFirst =
          (_ratio * avail + delta).clamp(widget.minFirst, maxFirst);
      _ratio = (newFirst / avail).clamp(0.0, 1.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final horizontal = widget.axis == Axis.horizontal;
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final total = horizontal ? constraints.maxWidth : constraints.maxHeight;
        final avail = (total - _dividerThickness).clamp(0.0, double.infinity);
        final maxFirst =
            (avail - widget.minSecond).clamp(widget.minFirst, avail);
        final firstExtent = (_ratio * avail).clamp(widget.minFirst, maxFirst);

        final lineColor = _hovering ? scheme.primary : scheme.outlineVariant;
        final divider = MouseRegion(
          cursor: horizontal
              ? SystemMouseCursors.resizeColumn
              : SystemMouseCursors.resizeRow,
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate:
                horizontal ? (d) => _drag(d.delta.dx, avail) : null,
            onHorizontalDragEnd:
                horizontal ? (_) => widget.onRatioSettled(_ratio) : null,
            onVerticalDragUpdate:
                horizontal ? null : (d) => _drag(d.delta.dy, avail),
            onVerticalDragEnd:
                horizontal ? null : (_) => widget.onRatioSettled(_ratio),
            child: Container(
              width: horizontal ? _dividerThickness : null,
              height: horizontal ? null : _dividerThickness,
              alignment: Alignment.center,
              color: Colors.transparent,
              // A thin centered line; the full thickness stays grabbable.
              child: Container(
                width: horizontal ? 1 : null,
                height: horizontal ? null : 1,
                color: lineColor,
              ),
            ),
          ),
        );

        final firstChild = SizedBox(
          width: horizontal ? firstExtent : null,
          height: horizontal ? null : firstExtent,
          child: widget.first,
        );

        final children = [firstChild, divider, Expanded(child: widget.second)];
        return horizontal
            ? Row(children: children)
            : Column(children: children);
      },
    );
  }
}
