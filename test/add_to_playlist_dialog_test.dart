import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/src/rust/catalog/playlists.dart';
import 'package:olivier/playlists/add_to_playlist_dialog.dart';
import 'package:olivier/state/playlists.dart';
import 'package:olivier/state/providers.dart';

void main() {
  testWidgets('picking an existing playlist adds the resolved paths',
      (tester) async {
    final added = <String>[];
    final fns = PlaylistFns(
      list: () async => [const Playlist(id: 5, name: 'Faves', count: 0)],
      create: (name) async => 9,
      rename: (id, name) async {},
      delete: (id) async {},
      reorder: (ids) async {},
      tracks: (id) async => const [],
      add: (id, paths) async => added.addAll(['$id', ...paths]),
      setItems: (id, paths) async {},
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        playlistFnsProvider.overrideWithValue(fns),
        entityPathFnsProvider.overrideWithValue(EntityPathFns(
          artistPaths: (_) async => [],
          albumPaths: (mbid) async => ['/m/a.flac', '/m/b.flac'],
          trackPath: (_) async => null,
        )),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: Consumer(builder: (context, ref, _) {
                return ElevatedButton(
                  onPressed: () => showAddToPlaylistDialog(
                      context, ref, const QueueEntityRef.album('R1')),
                  child: const Text('open'),
                );
              }),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Faves'));
    await tester.pumpAndSettle();

    expect(added, ['5', '/m/a.flac', '/m/b.flac']);
  });
}
