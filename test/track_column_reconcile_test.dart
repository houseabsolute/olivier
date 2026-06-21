import 'package:flutter/gestures.dart' show kSecondaryButton;
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

// GAP 2 for the track column: an FFI/DB failure must surface a snackbar and
// not escape as an unhandled exception.
void main() {
  testWidgets('track "Remove from library" shows a failure snackbar on error',
      (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/x.db', saveQueue: (_) async {});
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        tracksProvider.overrideWith((ref) => [_track]),
        selectedAlbumProvider.overrideWith(() => _StubAlbum('rel-1')),
        queueControllerProvider.overrideWithValue(qc),
        removeTrackFnProvider
            .overrideWithValue((id) async => throw Exception('boom')),
      ],
      child: const MaterialApp(home: Scaffold(body: TrackColumn())),
    ));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Remove from library'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Failed to remove "Song"'), findsOneWidget);
  });

  testWidgets('track "Re-read tags" shows a failure snackbar on error',
      (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/x.db', saveQueue: (_) async {});
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        tracksProvider.overrideWith((ref) => [_track]),
        selectedAlbumProvider.overrideWith(() => _StubAlbum('rel-1')),
        queueControllerProvider.overrideWithValue(qc),
        rereadTrackTagsFnProvider
            .overrideWithValue((id) async => throw Exception('boom')),
      ],
      child: const MaterialApp(home: Scaffold(body: TrackColumn())),
    ));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song')),
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
