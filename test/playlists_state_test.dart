import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/catalog/playlists.dart';
import 'package:olivier/state/playlists.dart';

/// In-memory fake of the playlist FFI so the notifier is testable without the
/// bridge. Records calls and behaves enough for refresh assertions.
class _FakeStore {
  final List<Playlist> lists = [];
  final List<String> calls = [];
  int _nextId = 1;

  PlaylistFns fns() => PlaylistFns(
        list: () async {
          calls.add('list');
          return List.of(lists);
        },
        create: (name) async {
          calls.add('create:$name');
          final id = _nextId++;
          lists.add(Playlist(id: id, name: name, count: 0));
          return id;
        },
        rename: (id, name) async => calls.add('rename:$id:$name'),
        delete: (id) async {
          calls.add('delete:$id');
          lists.removeWhere((p) => p.id == id);
        },
        reorder: (ids) async => calls.add('reorder:${ids.join(",")}'),
        tracks: (id) async {
          calls.add('tracks:$id');
          return [];
        },
        add: (id, paths) async => calls.add('add:$id:${paths.join(",")}'),
        setItems: (id, paths) async => calls.add('set:$id:${paths.join(",")}'),
      );
}

void main() {
  ProviderContainer containerWith(_FakeStore store) {
    final c = ProviderContainer(overrides: [
      playlistFnsProvider.overrideWithValue(store.fns()),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('build loads the list', () async {
    final store = _FakeStore()
      ..lists.add(const Playlist(id: 1, name: 'X', count: 0));
    final c = containerWith(store);
    final lists = await c.read(playlistsProvider.future);
    expect(lists.map((p) => p.name), ['X']);
  });

  test('create then refresh', () async {
    final store = _FakeStore();
    final c = containerWith(store);
    await c.read(playlistsProvider.future);
    final id = await c.read(playlistsProvider.notifier).create('New');
    expect(id, 1);
    expect(store.calls, contains('create:New'));
    expect(c.read(playlistsProvider).value!.map((p) => p.name), ['New']);
  });

  test('reorder and setItems and add forward to the store', () async {
    final store = _FakeStore();
    final c = containerWith(store);
    await c.read(playlistsProvider.future);
    final n = c.read(playlistsProvider.notifier);
    await n.reorder([3, 1, 2]);
    await n.setItems(7, ['/m/a.flac']);
    await n.addTracks(7, ['/m/b.flac']);
    expect(store.calls,
        containsAll(['reorder:3,1,2', 'set:7:/m/a.flac', 'add:7:/m/b.flac']));
  });
}
