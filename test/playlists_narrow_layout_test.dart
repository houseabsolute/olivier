import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/playlists/playlists_page.dart';
import 'package:olivier/src/rust/catalog/playlists.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
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
      addedAt: 0,
      lastPlayed: null,
      titleTranslit: null,
      titleTranslate: null,
      recordingMbid: null,
      albumArtistMbid: null,
    );

/// Minimal stand-in for the playlist FFI seam.
PlaylistFns _fns(List<Playlist> lists, Map<int, List<QueueTrack>> tracks) =>
    PlaylistFns(
      list: () async => List.of(lists),
      create: (name) async => 99,
      rename: (id, name) async {},
      delete: (id) async {},
      reorder: (ids) async {},
      tracks: (id) async => tracks[id] ?? const [],
      add: (id, paths) async {},
      setItems: (id, paths) async {},
    );

late ProviderContainer container;

Widget _page() {
  container = ProviderContainer(overrides: [
    dbPathProvider.overrideWithValue(':memory:'),
    getSettingFnProvider.overrideWithValue((k) async => null),
    playlistFnsProvider.overrideWithValue(_fns(
      [const Playlist(id: 1, name: 'Roadtrip', count: 2)],
      {
        1: [_track('/m/a.flac', 'Song A'), _track('/m/b.flac', 'Song B')]
      },
    )),
  ]);
  addTearDown(container.dispose);
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: PlaylistsPage()),
  );
}

Future<void> _pump(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_page());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('narrow: the list, then the playlist, then back', (tester) async {
    await _pump(tester, const Size(400, 800));

    expect(tester.takeException(), isNull);
    expect(find.text('Roadtrip'), findsOneWidget);
    // The detail pane is not beside the list.
    expect(find.text('Song A'), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    await tester.tap(find.text('Roadtrip'));
    await tester.pumpAndSettle();

    expect(find.text('Song A'), findsOneWidget);
    expect(find.text('Song B'), findsOneWidget);
    // The name moves into the app bar, so the header row has room to fit.
    expect(find.widgetWithText(AppBar, 'Roadtrip'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'no overflow at 400px');

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.text('Song A'), findsNothing);
    expect(find.text('Roadtrip'), findsOneWidget);
  });

  testWidgets('narrow: the actions still work', (tester) async {
    await _pump(tester, const Size(400, 800));
    await tester.tap(find.text('Roadtrip'));
    await tester.pumpAndSettle();

    for (final label in ['Play', 'Shuffle', 'Add to queue']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });

  testWidgets('narrow: creating a playlist does not throw', (tester) async {
    // A provider watched from inside the LayoutBuilder registers its dependency
    // during layout, and the write that follows creation then asserts
    // `owner!._debugCurrentBuildTarget != null`. Found on a device, not here.
    await _pump(tester, const Size(400, 800));

    container.read(selectedPlaylistProvider.notifier).select(1);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Song A'), findsOneWidget);
  });

  testWidgets('wide: the sidebar and detail stay side by side', (tester) async {
    await _pump(tester, const Size(1200, 800));

    expect(find.text('Roadtrip'), findsOneWidget);
    // Detail placeholder is visible alongside the list, without selecting.
    expect(find.text('Select a playlist'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    await tester.tap(find.text('Roadtrip'));
    await tester.pumpAndSettle();

    // Both panes at once: the name appears in the list and the detail header.
    expect(find.text('Song A'), findsOneWidget);
    expect(find.text('Roadtrip'), findsNWidgets(2));
  });
}
