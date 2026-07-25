import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/state/queue_view.dart';

/// Distance, in logical pixels, an upward drag must cover to count as a
/// deliberate swipe rather than a stray movement while reaching for the
/// transport. About half the bar's height, so it reads as "throw the bar up",
/// not a nudge.
const double kQueueSwipeUpDistance = 48;

/// The downward threshold has to be much smaller, because the bar sits against
/// the bottom of the screen and Android's gesture-navigation exclusion zone
/// eats the rest of the drag: measured on a Pixel 8a, a 400px upward swipe
/// reports 133 logical px, while downward swipes of 100px and 80px both report
/// only ~30 — the pointer stream stops once the drag enters the zone. Anything
/// at or above 48 would therefore be unreachable downward.
const double kQueueSwipeDownDistance = 16;

/// Wraps the now-playing bar so an upward swipe opens the queue and a downward
/// swipe closes it.
///
/// Toggles [queueExpandedProvider] — the same state the queue panel's caret
/// drives — rather than animating a sheet of its own, so there is one source of
/// truth for "is the queue showing" in both the wide and narrow layouts.
///
/// Vertical only: the bar contains a seek slider, which claims horizontal
/// drags, so the two gestures don't compete.
class QueueSwipeTarget extends ConsumerStatefulWidget {
  const QueueSwipeTarget({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<QueueSwipeTarget> createState() => _QueueSwipeTargetState();
}

class _QueueSwipeTargetState extends ConsumerState<QueueSwipeTarget> {
  /// Accumulated vertical movement of the drag in progress. Negative is up.
  double _dy = 0;

  /// Distance alone decides, deliberately — not release velocity. A real flick
  /// covers well past the threshold anyway, and velocity would add a branch
  /// that widget tests can't exercise: the synthesized events `fling` produces
  /// give the velocity tracker too few samples, so it always estimates zero.
  void _end(DragEndDetails details) {
    final up = _dy <= -kQueueSwipeUpDistance;
    final down = _dy >= kQueueSwipeDownDistance;
    _dy = 0;
    if (!up && !down) return;

    final notifier = ref.read(queueExpandedProvider.notifier);
    if (up) {
      if (!ref.read(queueExpandedProvider)) notifier.toggle();
    } else {
      notifier.collapse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Opaque so the drag is picked up over the bar's own inert areas; the
      // slider and transport buttons still get their own gestures first.
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) => _dy = 0,
      onVerticalDragUpdate: (d) => _dy += d.delta.dy,
      onVerticalDragEnd: _end,
      child: widget.child,
    );
  }
}
