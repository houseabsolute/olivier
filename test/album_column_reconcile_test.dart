import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/album_column.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';

import 'support/fake_queue_player.dart';

const _artist = Artist(mbid: 'art-1', name: 'Artist', sortName: 'Artist');

const _album = Album(
  releaseMbid: 'rel-1',
  title: 'Album One',
  albumArtist: 'Artist',
  addedAt: 0,
);

class _PreselectedArtist extends SelectedArtist {
  _PreselectedArtist(this._mbid);
  final String _mbid;
  @override
  String? build() => _mbid;
}

class _PreselectedAlbumObject extends SelectedAlbumObject {
  _PreselectedAlbumObject(this._album);
  final Album _album;
  @override
  Album? build() => _album;
}

void main() {
  // GAP 1: removing the artist's last album prunes the artist (Rust cascade).
  // The handler must reconcile the now-dangling selectedArtistProvider and
  // clear selectedAlbumObjectProvider.
  testWidgets(
      'album "Remove from library" reconciles a pruned artist selection',
      (tester) async {
    // Backing list the stateful artistsProvider reads from; the remove stub
    // mutates it to simulate the prune_orphans cascade.
    final backing = <Artist>[_artist];
    final qc = QueueController.withPlayer(
      FakeQueuePlayer(),
      dbPath: '/x.db',
      saveQueue: (_) async {},
    );
    final container = ProviderContainer(overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      // Stateful artistsProvider backed by a mutable list so invalidation
      // re-reads the post-prune contents.
      artistsProvider.overrideWith((ref) async => List.of(backing)),
      albumsProvider.overrideWith((ref) => [_album]),
      selectedArtistProvider.overrideWith(() => _PreselectedArtist('art-1')),
      selectedAlbumObjectProvider
          .overrideWith(() => _PreselectedAlbumObject(_album)),
      queueControllerProvider.overrideWithValue(qc),
      tracksForPathsFnProvider.overrideWithValue((paths) async => []),
      // Removing the album drops the artist from the backing list (prune).
      removeAlbumFnProvider.overrideWithValue((mbid) async {
        backing.removeWhere((a) => a.mbid == 'art-1');
      }),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: AlbumColumn())),
    ));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Album One')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Remove from library'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Artist no longer present in the refreshed list → selection reconciled.
    expect(container.read(selectedArtistProvider), isNull);
    // The cached album object is cleared too.
    expect(container.read(selectedAlbumObjectProvider), isNull);
  });

  // GAP 2: an FFI/DB failure must surface a snackbar and not escape as an
  // unhandled exception.
  testWidgets('album "Remove from library" shows a failure snackbar on error',
      (tester) async {
    final qc = QueueController.withPlayer(
      FakeQueuePlayer(),
      dbPath: '/x.db',
      saveQueue: (_) async {},
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        albumsProvider.overrideWith((ref) => [_album]),
        queueControllerProvider.overrideWithValue(qc),
        removeAlbumFnProvider
            .overrideWithValue((mbid) async => throw Exception('boom')),
      ],
      child: const MaterialApp(home: Scaffold(body: AlbumColumn())),
    ));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Album One')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Remove from library'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Failed to remove "Album One"'), findsOneWidget);
  });

  testWidgets('album "Re-read tags" shows a failure snackbar on error',
      (tester) async {
    final qc = QueueController.withPlayer(
      FakeQueuePlayer(),
      dbPath: '/x.db',
      saveQueue: (_) async {},
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        albumsProvider.overrideWith((ref) => [_album]),
        queueControllerProvider.overrideWithValue(qc),
        rereadAlbumTagsFnProvider
            .overrideWithValue((mbid) async => throw Exception('boom')),
      ],
      child: const MaterialApp(home: Scaffold(body: AlbumColumn())),
    ));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Album One')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Re-read tags'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Failed to re-read tags'), findsOneWidget);
  });
}
