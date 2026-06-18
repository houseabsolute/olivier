import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/api/catalog.dart' as catalog;
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

/// Immutable snapshot of the queue for the panel to render, in canonical order.
class QueueView {
  const QueueView({
    required this.tracks,
    required this.currentIndex,
    required this.shuffled,
  });

  final List<QueueTrack> tracks;

  /// Canonical index (into [tracks]) of the currently-playing entry, or null
  /// when the queue is empty / nothing is current.
  final int? currentIndex;
  final bool shuffled;

  static const empty =
      QueueView(tracks: <QueueTrack>[], currentIndex: null, shuffled: false);
}

/// FFI seam so [QueueNotifier] is unit-testable without the real bridge.
typedef TracksForPathsFn = Future<List<QueueTrack>> Function(
    List<String> paths);

final tracksForPathsFnProvider = Provider<TracksForPathsFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (paths) => catalog.tracksForPaths(dbPath: db, paths: paths);
});

class QueueNotifier extends AsyncNotifier<QueueView> {
  QueueController get _controller => ref.read(queueControllerProvider);

  @override
  Future<QueueView> build() async {
    final controller = _controller;

    // Re-resolve whenever the controller mutates the queue.
    void onRevision() => ref.invalidateSelf();
    controller.revision.addListener(onRevision);
    ref.onDispose(() => controller.revision.removeListener(onRevision));

    // Re-emit when the player advances so the canonical current-index highlight
    // stays up-to-date (shuffle-aware via currentCanonicalIndex).
    final sub =
        controller.currentIndexStream.listen((_) => ref.invalidateSelf());
    ref.onDispose(sub.cancel);

    return _resolve();
  }

  Future<QueueView> _resolve() async {
    final controller = _controller;
    final paths = controller.orderedPaths;
    if (paths.isEmpty) return QueueView.empty;

    final tracks = await ref.read(tracksForPathsFnProvider)(paths);
    return QueueView(
      tracks: tracks,
      currentIndex: controller.currentCanonicalIndex,
      shuffled: controller.shuffled,
    );
  }
}

final queueProvider =
    AsyncNotifierProvider<QueueNotifier, QueueView>(QueueNotifier.new);
