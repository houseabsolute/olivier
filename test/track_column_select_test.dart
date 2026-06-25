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
import 'package:olivier/state/queue_provider.dart';
import 'package:olivier/widgets/title_override_dialog.dart';

import 'support/fake_queue_player.dart';

final _track = Track(id: 7, disc: 1, position: 1, title: 'Song', addedAt: 0);
final _trackWithRecording = Track(
  id: 7,
  disc: 1,
  position: 1,
  title: 'Song',
  addedAt: 0,
  recordingMbid: 'rec-1',
);

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

  testWidgets('track menu "Remove from library" calls the seam + snackbar',
      (tester) async {
    final removed = <int>[];
    final qc = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/x.db', saveQueue: (_) async {});
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        tracksProvider.overrideWith((ref) => [_track]),
        selectedAlbumProvider.overrideWith(() => _StubAlbum('rel-1')),
        queueControllerProvider.overrideWithValue(qc),
        tracksForPathsFnProvider.overrideWithValue((paths) async => []),
        removeTrackFnProvider.overrideWithValue((id) async => removed.add(id)),
      ],
      child: const MaterialApp(
        home: Scaffold(body: TrackColumn()),
      ),
    ));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Remove from library'), findsOneWidget);
    await tester.tap(find.text('Remove from library'));
    await tester.pumpAndSettle();

    expect(removed, [7]);
    expect(find.text('Removed "Song"'), findsOneWidget);
  });

  testWidgets('track menu "Set reading…" opens the override dialog',
      (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/x.db', saveQueue: (_) async {});
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        tracksProvider.overrideWith((ref) => [_trackWithRecording]),
        selectedAlbumProvider.overrideWith(() => _StubAlbum('rel-1')),
        queueControllerProvider.overrideWithValue(qc),
        trackTitleOverrideFnProvider.overrideWithValue(
          (mbid) async => const TitleOverride(
            translit: 'Songu',
            translate: null,
            translitOverride: null,
            translateOverride: null,
          ),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(
            body: SizedBox(width: 320, height: 600, child: TrackColumn())),
      ),
    ));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Set reading…'), findsOneWidget);
    await tester.tap(find.text('Set reading…'));
    await tester.pumpAndSettle();

    expect(find.byType(TitleOverrideDialog), findsOneWidget);
  });
}
