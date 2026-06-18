import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/album_column.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

import 'support/fake_queue_player.dart';

const _album = Album(
  releaseMbid: 'rel-1',
  title: 'Album One',
  albumArtist: 'Artist',
);

void main() {
  testWidgets('album rows have no play button', (tester) async {
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
        albumFilePathsFnProvider
            .overrideWithValue((mbid) async => ['/m/a.flac', '/m/b.flac']),
      ],
      child: const MaterialApp(home: Scaffold(body: AlbumColumn())),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.play_arrow), findsNothing);
  });

  testWidgets('double-tapping an album appends its tracks', (tester) async {
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
        albumFilePathsFnProvider
            .overrideWithValue((mbid) async => ['/m/a.flac', '/m/b.flac']),
      ],
      child: const MaterialApp(home: Scaffold(body: AlbumColumn())),
    ));
    await tester.pumpAndSettle();

    final row = find.text('Album One');
    await tester.tap(row);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(qc.orderedPaths, ['/m/a.flac', '/m/b.flac']);
  });
}
