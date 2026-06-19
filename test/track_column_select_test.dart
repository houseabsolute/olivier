import 'package:flutter/gestures.dart'
    show kDoubleTapMinTime, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
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

ProviderScope _app(QueueController qc) => ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        tracksProvider.overrideWith((ref) => [_track]),
        selectedAlbumProvider.overrideWith(() => _StubAlbum('rel-1')),
        queueControllerProvider.overrideWithValue(qc),
        trackPathFnProvider.overrideWithValue((id) async => '/m/song.flac'),
      ],
      child: const MaterialApp(
        home: Scaffold(
            body: SizedBox(width: 320, height: 600, child: TrackColumn())),
      ),
    );

void main() {
  testWidgets('single tap selects the track and does not play', (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/x.db', saveQueue: (_) async {});
    final container = ProviderContainer(overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      tracksProvider.overrideWith((ref) => [_track]),
      selectedAlbumProvider.overrideWith(() => _StubAlbum('rel-1')),
      queueControllerProvider.overrideWithValue(qc),
      trackPathFnProvider.overrideWithValue((id) async => '/m/song.flac'),
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
    // InkWell with both onTap + onDoubleTap defers onTap until the
    // double-tap window closes; advance past it before asserting.
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull); // no playbackController read
    expect(container.read(selectedTrackProvider), 7);
    expect(qc.orderedPaths, isEmpty); // selection must not enqueue
  });

  testWidgets('double tap resolves the path and appends to the queue',
      (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/x.db', saveQueue: (_) async {});
    await tester.pumpWidget(_app(qc));
    await tester.pumpAndSettle();

    final row = find.text('Song');
    await tester.tap(row);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(qc.orderedPaths, ['/m/song.flac']);
  });
}
