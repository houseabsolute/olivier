import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/catalog/album_column.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

import 'support/fake_queue_player.dart';

const _album = Album(
  releaseMbid: 'rel-1',
  title: 'Album One',
  albumArtist: 'Artist',
  addedAt: 0,
);

ProviderScope _albumApp(QueueController qc) => ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        albumsProvider.overrideWith((ref) => [_album]),
        queueControllerProvider.overrideWithValue(qc),
        entityPathFnsProvider.overrideWithValue(EntityPathFns(
          artistPaths: (_) async => [],
          albumPaths: (_) async => ['/m/a.flac', '/m/b.flac'],
          trackPath: (_) async => null,
        )),
      ],
      child: const MaterialApp(home: Scaffold(body: AlbumColumn())),
    );

void main() {
  testWidgets('album rows have no play button', (tester) async {
    final qc = QueueController.withPlayer(
      FakeQueuePlayer(),
      dbPath: '/x.db',
      saveQueue: (_) async {},
    );
    await tester.pumpWidget(_albumApp(qc));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.play_arrow), findsNothing);
  });

  testWidgets('album "Add to queue" menu appends its tracks', (tester) async {
    final qc = QueueController.withPlayer(
      FakeQueuePlayer(),
      dbPath: '/x.db',
      saveQueue: (_) async {},
    );
    await tester.pumpWidget(_albumApp(qc));
    await tester.pumpAndSettle();

    final g = await tester.startGesture(
      tester.getCenter(find.text('Album One')),
      buttons: kSecondaryButton,
    );
    await g.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(qc.orderedPaths, ['/m/a.flac', '/m/b.flac']);
  });

  testWidgets('album menu "Re-read tags" calls the seam + shows a snackbar',
      (tester) async {
    final reread = <String>[];
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
            .overrideWithValue((mbid) async => reread.add(mbid)),
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

    expect(find.text('Re-read tags'), findsOneWidget);
    await tester.tap(find.text('Re-read tags'));
    await tester.pumpAndSettle();

    expect(reread, ['rel-1']);
    expect(find.text('Tags re-read'), findsOneWidget);
  });

  testWidgets('album menu "Remove from library" calls the seam + snackbar',
      (tester) async {
    final removed = <String>[];
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
            .overrideWithValue((mbid) async => removed.add(mbid)),
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

    expect(find.text('Remove from library'), findsOneWidget);
    await tester.tap(find.text('Remove from library'));
    await tester.pumpAndSettle();

    expect(removed, ['rel-1']);
    expect(find.text('Removed "Album One"'), findsOneWidget);
  });

  // Spec §4: single-click selects the album (updates selectedAlbumProvider) and
  // must NOT enqueue/play anything — the queue stays empty.
  testWidgets('single-tapping an album selects it without enqueueing',
      (tester) async {
    final qc = QueueController.withPlayer(
      FakeQueuePlayer(),
      dbPath: '/x.db',
      saveQueue: (_) async {},
    );
    // Use a ProviderContainer so we can read selectedAlbumProvider afterward.
    final container = ProviderContainer(overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      albumsProvider.overrideWith((ref) => [_album]),
      queueControllerProvider.overrideWithValue(qc),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: AlbumColumn())),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Album One'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    // Selection updated.
    expect(container.read(selectedAlbumProvider), 'rel-1');
    // Queue must remain empty.
    expect(qc.orderedPaths, isEmpty);
  });
}
