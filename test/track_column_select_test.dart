import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/catalog/track_column.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

import 'support/fake_queue_player.dart';

final _track = Track(id: 7, disc: 1, position: 1, title: 'Song', addedAt: 0);

class _StubAlbum extends SelectedAlbum {
  _StubAlbum(this._initial);
  final String _initial;
  @override
  String? build() => _initial;
}

void main() {
  testWidgets('single tap selects the track and does not play', (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/x.db', saveQueue: (_) async {});
    final container = ProviderContainer(overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      tracksProvider.overrideWith((ref) => [_track]),
      selectedAlbumProvider.overrideWith(() => _StubAlbum('rel-1')),
      queueControllerProvider.overrideWithValue(qc),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: TrackColumn()),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Song'));
    await tester.pump();

    expect(tester.takeException(), isNull); // no playbackController read
    expect(container.read(selectedTrackProvider), 7);
    expect(qc.orderedPaths, isEmpty); // selection must not enqueue
  });

  testWidgets('"Add to queue" menu resolves the path and appends to the queue',
      (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/x.db', saveQueue: (_) async {});
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        tracksProvider.overrideWith((ref) => [_track]),
        selectedAlbumProvider.overrideWith(() => _StubAlbum('rel-1')),
        queueControllerProvider.overrideWithValue(qc),
        entityPathFnsProvider.overrideWithValue(EntityPathFns(
          artistPaths: (_) async => [],
          albumPaths: (_) async => [],
          trackPath: (_) async => '/m/song.flac',
        )),
      ],
      child: const MaterialApp(
        home: Scaffold(
            body: SizedBox(width: 320, height: 600, child: TrackColumn())),
      ),
    ));
    await tester.pumpAndSettle();

    final g = await tester.startGesture(
      tester.getCenter(find.text('Song')),
      buttons: kSecondaryButton,
    );
    await g.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(qc.orderedPaths, ['/m/song.flac']);
  });
}
