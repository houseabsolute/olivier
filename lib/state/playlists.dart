// frb maps Vec<i64> to its own Int64List (not dart:typed_data's), so import the
// type from flutter_rust_bridge to construct the reorderPlaylists argument.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/src/rust/api/playlists.dart' as ffi;
import 'package:olivier/src/rust/catalog/playlists.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

/// FFI seam bundle so the notifier/page are testable without the bridge.
class PlaylistFns {
  const PlaylistFns({
    required this.list,
    required this.create,
    required this.rename,
    required this.delete,
    required this.reorder,
    required this.tracks,
    required this.add,
    required this.setItems,
  });

  final Future<List<Playlist>> Function() list;
  final Future<int> Function(String name) create;
  final Future<void> Function(int id, String name) rename;
  final Future<void> Function(int id) delete;
  final Future<void> Function(List<int> ids) reorder;
  final Future<List<QueueTrack>> Function(int id) tracks;
  final Future<void> Function(int id, List<String> paths) add;
  final Future<void> Function(int id, List<String> paths) setItems;
}

final playlistFnsProvider = Provider<PlaylistFns>((ref) {
  final db = ref.watch(dbPathProvider);
  return PlaylistFns(
    list: () => ffi.listPlaylists(dbPath: db),
    create: (name) => ffi.createPlaylist(dbPath: db, name: name),
    rename: (id, name) => ffi.renamePlaylist(dbPath: db, id: id, name: name),
    delete: (id) => ffi.deletePlaylist(dbPath: db, id: id),
    reorder: (ids) =>
        ffi.reorderPlaylists(dbPath: db, ids: Int64List.fromList(ids)),
    tracks: (id) => ffi.playlistTracks(dbPath: db, id: id),
    add: (id, paths) => ffi.addToPlaylist(dbPath: db, id: id, paths: paths),
    setItems: (id, paths) =>
        ffi.setPlaylistItems(dbPath: db, id: id, paths: paths),
  );
});

class PlaylistsNotifier extends AsyncNotifier<List<Playlist>> {
  PlaylistFns get _fns => ref.read(playlistFnsProvider);

  @override
  Future<List<Playlist>> build() => _fns.list();

  Future<void> _refresh() async {
    state = await AsyncValue.guard(_fns.list);
  }

  Future<int> create(String name) async {
    final id = await _fns.create(name);
    await _refresh();
    return id;
  }

  Future<void> rename(int id, String name) async {
    await _fns.rename(id, name);
    await _refresh();
  }

  Future<void> delete(int id) async {
    await _fns.delete(id);
    await _refresh();
  }

  Future<void> reorder(List<int> ids) async {
    await _fns.reorder(ids);
    await _refresh();
  }

  Future<void> addTracks(int id, List<String> paths) async {
    await _fns.add(id, paths);
    ref.invalidate(playlistTracksProvider(id));
    await _refresh();
  }

  Future<void> setItems(int id, List<String> paths) async {
    await _fns.setItems(id, paths);
    ref.invalidate(playlistTracksProvider(id));
    await _refresh();
  }
}

final playlistsProvider =
    AsyncNotifierProvider<PlaylistsNotifier, List<Playlist>>(
        PlaylistsNotifier.new);

class SelectedPlaylist extends Notifier<int?> {
  @override
  int? build() => null;
  void select(int? id) => state = id;
}

final selectedPlaylistProvider =
    NotifierProvider<SelectedPlaylist, int?>(SelectedPlaylist.new);

final playlistTracksProvider =
    FutureProvider.family<List<QueueTrack>, int>((ref, id) {
  return ref.watch(playlistFnsProvider).tracks(id);
});

/// Playback seam: maps the three playlist actions onto QueueController, so the
/// page is testable without a live player.
class PlaylistPlayback {
  const PlaylistPlayback({
    required this.play,
    required this.shuffle,
    required this.addToQueue,
  });
  final Future<void> Function(List<String> paths) play;
  final Future<void> Function(List<String> paths) shuffle;
  final Future<void> Function(List<String> paths) addToQueue;
}

final playlistPlaybackProvider = Provider<PlaylistPlayback>((ref) {
  final qc = ref.read(queueControllerProvider);
  return PlaylistPlayback(
    play: (paths) async {
      await qc.setQueue(paths);
      await qc.playAt(0);
    },
    shuffle: (paths) => qc.replaceLibraryShuffled(paths),
    addToQueue: (paths) => qc.append(paths),
  );
});
