import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/catalog/album_column.dart';
import 'package:olivier/playlists/playlists_page.dart';
import 'package:olivier/src/rust/catalog/playlists.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/list_selection.dart';
import 'package:olivier/state/playlists.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';

import 'support/fake_queue_player.dart';

const _albums = [
  Album(releaseMbid: 'rel-1', title: 'One', albumArtist: 'A', addedAt: 0),
  Album(releaseMbid: 'rel-2', title: 'Two', albumArtist: 'A', addedAt: 0),
  Album(releaseMbid: 'rel-3', title: 'Three', albumArtist: 'A', addedAt: 0),
];

QueueTrack _qt(String path, String title) =>
    QueueTrack(path: path, title: title, album: 'Album', addedAt: 0);

Future<void> _tapWith(
  WidgetTester tester,
  LogicalKeyboardKey key,
  Finder finder,
) async {
  await tester.sendKeyDownEvent(key);
  await tester.tap(finder);
  await tester.sendKeyUpEvent(key);
  await tester.pumpAndSettle();
}

Future<void> _openMenu(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    buttons: kSecondaryButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  group('album column', () {
    late List<String> removedAlbums;

    ProviderContainer container(QueueController qc) {
      removedAlbums = [];
      return ProviderContainer(overrides: [
        dbPathProvider.overrideWithValue(':memory:'),
        getSettingFnProvider.overrideWithValue((k) async => null),
        albumsProvider.overrideWith((ref) => _albums),
        queueControllerProvider.overrideWithValue(qc),
        entityPathFnsProvider.overrideWithValue(EntityPathFns(
          artistPaths: (_) async => [],
          // Two tracks per album, so the enqueue order is visible.
          albumPaths: (mbid) async => ['/$mbid/1.flac', '/$mbid/2.flac'],
          trackPath: (_) async => null,
        )),
        removeAlbumFnProvider
            .overrideWithValue((mbid) async => removedAlbums.add(mbid)),
        artistsProvider.overrideWith((ref) => <Artist>[]),
        tracksProvider.overrideWith((ref) => <Track>[]),
        tracksForPathsFnProvider.overrideWithValue((paths) async => []),
      ]);
    }

    Future<void> pump(WidgetTester tester, ProviderContainer c) async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: AlbumColumn())),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('enqueues every selected album, in list order', (tester) async {
      final qc = QueueController.withPlayer(FakeQueuePlayer(),
          dbPath: '/x.db', saveQueue: (_) async {});
      final c = container(qc);
      addTearDown(c.dispose);
      await pump(tester, c);

      await tester.tap(find.text('Three'));
      await tester.pumpAndSettle();
      await _tapWith(tester, LogicalKeyboardKey.controlLeft, find.text('One'));

      await _openMenu(tester, find.text('One'));
      expect(find.text('Add 2 albums to queue'), findsOneWidget);
      await tester.tap(find.text('Add 2 albums to queue'));
      await tester.pumpAndSettle();

      expect(qc.orderedPaths, [
        '/rel-1/1.flac',
        '/rel-1/2.flac',
        '/rel-3/1.flac',
        '/rel-3/2.flac',
      ]);
    });

    testWidgets('removes every selected album from the library',
        (tester) async {
      final qc = QueueController.withPlayer(FakeQueuePlayer(),
          dbPath: '/x.db', saveQueue: (_) async {});
      final c = container(qc);
      addTearDown(c.dispose);
      await pump(tester, c);

      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();
      await _tapWith(tester, LogicalKeyboardKey.shiftLeft, find.text('Two'));

      await _openMenu(tester, find.text('Two'));
      await tester.tap(find.text('Remove 2 albums from library'));
      await tester.pumpAndSettle();

      expect(removedAlbums, ['rel-1', 'rel-2']);
      expect(c.read(albumSelectionProvider).isEmpty, isTrue);
    });
  });

  group('playlist detail', () {
    late List<String> setItemsCalls;
    late List<String> queued;

    PlaylistFns fns(List<Playlist> lists, Map<int, List<QueueTrack>> tracks) =>
        PlaylistFns(
          list: () async => List.of(lists),
          create: (name) async => 99,
          rename: (id, name) async {},
          delete: (id) async {},
          reorder: (ids) async {},
          tracks: (id) async => tracks[id] ?? const [],
          add: (id, paths) async {},
          setItems: (id, paths) async => setItemsCalls.add(paths.join(',')),
        );

    Widget harness() => ProviderScope(
          overrides: [
            getSettingFnProvider.overrideWithValue((k) async => null),
            playlistFnsProvider.overrideWithValue(fns(
              [const Playlist(id: 1, name: 'Roadtrip', count: 3)],
              {
                1: [
                  _qt('/m/a.flac', 'Song A'),
                  _qt('/m/b.flac', 'Song B'),
                  _qt('/m/c.flac', 'Song C'),
                ]
              },
            )),
            playlistPlaybackProvider.overrideWithValue(PlaylistPlayback(
              play: (paths) async {},
              shuffle: (paths) async {},
              addToQueue: (paths) async => queued
                ..clear()
                ..addAll(paths),
            )),
          ],
          child: const MaterialApp(home: PlaylistsPage()),
        );

    setUp(() {
      setItemsCalls = [];
      queued = [];
    });

    Future<void> open(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Roadtrip'));
      await tester.pumpAndSettle();
    }

    testWidgets('queues the selected playlist rows', (tester) async {
      await open(tester);

      await tester.tap(find.text('Song A'));
      await tester.pumpAndSettle();
      await _tapWith(
          tester, LogicalKeyboardKey.controlLeft, find.text('Song C'));

      await _openMenu(tester, find.text('Song C'));
      await tester.tap(find.text('Add 2 tracks to queue'));
      await tester.pumpAndSettle();

      expect(queued, ['/m/a.flac', '/m/c.flac']);
    });

    testWidgets('removes the selected rows from the playlist', (tester) async {
      await open(tester);

      await tester.tap(find.text('Song A'));
      await tester.pumpAndSettle();
      await _tapWith(tester, LogicalKeyboardKey.shiftLeft, find.text('Song B'));

      await _openMenu(tester, find.text('Song B'));
      expect(find.text('Remove 2 tracks from playlist'), findsOneWidget);
      await tester.tap(find.text('Remove 2 tracks from playlist'));
      await tester.pumpAndSettle();

      // Only the untouched row survives.
      expect(setItemsCalls, ['/m/c.flac']);
    });
  });
}
