import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/catalog/playlists.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/playlists/playlists_page.dart';
import 'package:olivier/state/playlists.dart';
import 'package:olivier/state/providers.dart';

QueueTrack _track(String path, String title) => QueueTrack(
      path: path,
      trackId: null,
      title: title,
      artist: 'Artist',
      album: 'Album',
      albumArtist: null,
      albumArtistOriginal: null,
      albumArtistReading: null,
      lengthMs: null,
      addedAt: 0, // PlatformInt64 == int on native
      lastPlayed: null,
      titleTranslit: null,
      titleTranslate: null,
      recordingMbid: null,
      albumArtistMbid: null,
    );

void main() {
  late List<String> played;
  late List<String> setItemsCalls;

  PlaylistFns fakeFns(List<Playlist> lists, Map<int, List<QueueTrack>> tracks) =>
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

  Widget harness(List<Override> overrides) => ProviderScope(
        overrides: [
          getSettingFnProvider.overrideWithValue((k) async => null),
          ...overrides,
        ],
        child: const MaterialApp(home: PlaylistsPage()),
      );

  setUp(() {
    played = [];
    setItemsCalls = [];
  });

  // The master-detail header (Play/Shuffle/Add-to-queue/Rename/Delete) is wider
  // than the default 800px test surface; size it like the real desktop window so
  // the detail Row doesn't overflow during layout.
  Future<void> wideSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets('shows playlists and their tracks on selection', (tester) async {
    await wideSurface(tester);
    await tester.pumpWidget(harness([
      playlistFnsProvider.overrideWithValue(fakeFns(
        [const Playlist(id: 1, name: 'Roadtrip', count: 2)],
        {
          1: [_track('/m/a.flac', 'Song A'), _track('/m/b.flac', 'Song B')]
        },
      )),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Roadtrip'), findsOneWidget);
    await tester.tap(find.text('Roadtrip'));
    await tester.pumpAndSettle();
    expect(find.text('Song A'), findsOneWidget);
    expect(find.text('Song B'), findsOneWidget);
  });

  testWidgets('Play sends the playlist paths to the playback seam',
      (tester) async {
    await wideSurface(tester);
    await tester.pumpWidget(harness([
      playlistFnsProvider.overrideWithValue(fakeFns(
        [const Playlist(id: 1, name: 'Roadtrip', count: 2)],
        {
          1: [_track('/m/a.flac', 'Song A'), _track('/m/b.flac', 'Song B')]
        },
      )),
      playlistPlaybackProvider.overrideWithValue(PlaylistPlayback(
        play: (paths) async => played
          ..clear()
          ..addAll(paths),
        shuffle: (paths) async {},
        addToQueue: (paths) async {},
      )),
    ]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Roadtrip'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Play'));
    await tester.pumpAndSettle();
    expect(played, ['/m/a.flac', '/m/b.flac']);
  });
}
