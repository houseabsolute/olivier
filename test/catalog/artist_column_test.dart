import 'package:flutter/gestures.dart'
    show kDoubleTapMinTime, kDoubleTapTimeout, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/catalog/artist_column.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

import '../support/fake_queue_player.dart';

const _artist =
    Artist(mbid: 'mbid-1', name: 'Test Artist', sortName: 'Artist, Test');

const _fakePaths = ['/music/a.flac', '/music/b.flac'];

/// Build a test app for [ArtistColumn] with overridden seam providers.
ProviderScope _artistApp(
  QueueController qc, {
  EntityPathFns? pathFns,
}) {
  final fns = pathFns ??
      EntityPathFns(
        artistPaths: (_) async => _fakePaths,
        albumPaths: (_) async => [],
        trackPath: (_) async => null,
      );
  return ProviderScope(
    overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      artistsProvider.overrideWith((ref) => [_artist]),
      queueControllerProvider.overrideWithValue(qc),
      entityPathFnsProvider.overrideWithValue(fns),
    ],
    child: const MaterialApp(home: Scaffold(body: ArtistColumn())),
  );
}

void main() {
  // Spec §4: single-click selects the artist (updates selectedArtistProvider)
  // and must NOT enqueue/play anything — the queue stays empty.
  testWidgets('single-tapping an artist selects it without enqueueing',
      (tester) async {
    final qc = QueueController.withPlayer(
      FakeQueuePlayer(),
      dbPath: '/x.db',
      saveQueue: (_) async {},
    );
    final container = ProviderContainer(overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      artistsProvider.overrideWith((ref) => [_artist]),
      queueControllerProvider.overrideWithValue(qc),
      entityPathFnsProvider.overrideWithValue(EntityPathFns(
        artistPaths: (_) async => _fakePaths,
        albumPaths: (_) async => [],
        trackPath: (_) async => null,
      )),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ArtistColumn())),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Test Artist'));
    // Wait past double-tap window so onTap fires.
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Selection updated.
    expect(container.read(selectedArtistProvider), 'mbid-1');
    // Queue must remain empty — selection does not enqueue.
    expect(qc.orderedPaths, isEmpty);
  });

  // Spec §4: double-tap appends the artist's tracks to the queue.
  testWidgets('double-tapping an artist appends its tracks to the queue',
      (tester) async {
    final qc = QueueController.withPlayer(
      FakeQueuePlayer(),
      dbPath: '/x.db',
      saveQueue: (_) async {},
    );
    await tester.pumpWidget(_artistApp(qc));
    await tester.pumpAndSettle();

    final row = find.text('Test Artist');
    await tester.tap(row);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(qc.orderedPaths, _fakePaths);
  });

  testWidgets('artist row context menu offers Set reading…', (tester) async {
    final qc = QueueController.withPlayer(
      FakeQueuePlayer(),
      dbPath: '/x.db',
      saveQueue: (_) async {},
    );
    await tester.pumpWidget(_artistApp(qc));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Test Artist')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Set reading…'), findsOneWidget);
  });
}
