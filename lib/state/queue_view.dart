import 'package:flutter_riverpod/flutter_riverpod.dart';

/// View state for the queue panel. Lives in state/ rather than the panel widget
/// because BrowserPage and the search cascade both drive it, and importing the
/// panel from those call sites would drag the whole queue UI along with it.

/// Whether the queue panel is expanded to fill the browse area, hiding the
/// browse panes.
class QueueExpanded extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
  void collapse() => state = false;
}

final queueExpandedProvider =
    NotifierProvider<QueueExpanded, bool>(QueueExpanded.new);

/// Whether the expanded queue shows already-played tracks (those before the
/// current one). Off by default so the current track stays pinned at the top.
/// Session-only (resets on relaunch), like [queueExpandedProvider].
class ShowPlayed extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
}

final showPlayedProvider = NotifierProvider<ShowPlayed, bool>(ShowPlayed.new);

/// Canonical index of the first row the expanded queue should show. Hiding
/// played tracks (the default) starts at the current track so it's pinned at the
/// top; showing played tracks — or nothing playing — starts at 0. Clamped to
/// [0, trackCount] so a stale/out-of-range currentIndex can't over-run the list.
///
/// [ended] (the player finished the last entry) counts the final track as
/// played, so hiding played tracks then shows nothing rather than leaving the
/// track that just finished sitting at the top as if it were still up.
int queueVisibleStart({
  required bool showPlayed,
  required int? currentIndex,
  required int trackCount,
  bool ended = false,
}) {
  if (showPlayed) return 0;
  if (ended) return trackCount;
  if (currentIndex == null) return 0;
  return currentIndex.clamp(0, trackCount);
}
