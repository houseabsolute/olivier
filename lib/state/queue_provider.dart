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

/// After a catalog removal, drop from the live queue any path no longer in the
/// catalog (a track/album/root just removed). [tracksForPaths] returns one entry
/// per path with `trackId == null` for paths gone from the catalog. Best-effort:
/// callers run it last so a transient read error can't disrupt the removal.
Future<void> reconcileQueueWithCatalog(
  QueueController controller,
  Future<List<QueueTrack>> Function(List<String> paths) tracksForPaths,
) async {
  final paths = controller.orderedPaths;
  if (paths.isEmpty) return;
  final tracks = await tracksForPaths(paths);
  final missing = <String>{
    for (final t in tracks)
      if (t.trackId == null) t.path,
  };
  if (missing.isNotEmpty) await controller.removePaths(missing);
}

class QueueNotifier extends AsyncNotifier<QueueView> {
  QueueController get _controller => ref.read(queueControllerProvider);

  /// Cached track list from the last _resolve(). Reused by the cheap index
  /// update path so we never call FFI again just because the player advanced.
  List<QueueTrack> _cachedTracks = [];

  /// The last canonical index we pushed to state. Used to deduplicate
  /// currentIndexStream emits — just_audio re-emits on every playback event,
  /// not only on actual index changes.
  int? _lastPushedIndex;

  @override
  Future<QueueView> build() async {
    final controller = _controller;

    // Re-resolve whenever the controller mutates the queue (structural change).
    void onRevision() => ref.invalidateSelf();
    controller.revision.addListener(onRevision);
    ref.onDispose(() => controller.revision.removeListener(onRevision));

    // When the player advances to a new track, update only the highlight
    // (currentIndex) without re-resolving the full track list via FFI.
    // just_audio's currentIndexStream is NOT distinct — it re-emits on every
    // playback event (including during loading/buffering), so we deduplicate
    // manually and guard against not-yet-resolved state.
    final sub = controller.currentIndexStream.listen((_) {
      final idx = controller.currentCanonicalIndex;

      // Deduplicate: skip if the index didn't actually change.
      if (idx == _lastPushedIndex) return;

      // Guard: if we don't have a resolved state yet, let the upcoming
      // build()-triggered _resolve() set it instead.
      final current = state.value;
      if (current == null) return;

      _lastPushedIndex = idx;
      state = AsyncData(QueueView(
        tracks: _cachedTracks,
        currentIndex: idx,
        shuffled: controller.shuffled,
      ));
    });
    ref.onDispose(sub.cancel);

    return _resolve();
  }

  Future<QueueView> _resolve() async {
    final controller = _controller;
    final paths = controller.orderedPaths;
    if (paths.isEmpty) {
      _cachedTracks = [];
      _lastPushedIndex = null;
      return QueueView.empty;
    }

    final tracks = await ref.read(tracksForPathsFnProvider)(paths);
    _cachedTracks = tracks;
    final idx = controller.currentCanonicalIndex;
    _lastPushedIndex = idx;
    return QueueView(
      tracks: tracks,
      currentIndex: idx,
      shuffled: controller.shuffled,
    );
  }
}

final queueProvider =
    AsyncNotifierProvider<QueueNotifier, QueueView>(QueueNotifier.new);
