import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/track_column.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

final _track = Track(id: 7, disc: 1, position: 1, title: 'Song', addedAt: 0);

class _StubAlbum extends SelectedAlbum {
  @override
  String? build() => 'rel-1';
}

void main() {
  testWidgets('Re-read tags calls the FFI seam with the track id',
      (tester) async {
    int? reread;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((k) async => null),
        tracksProvider.overrideWith((ref) => [_track]),
        selectedAlbumProvider.overrideWith(_StubAlbum.new),
        rereadTrackTagsFnProvider.overrideWithValue((id) async => reread = id),
      ],
      child: const MaterialApp(home: Scaffold(body: TrackColumn())),
    ));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
        tester.getCenter(find.text('1. Song')),
        buttons: kSecondaryButton);
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Re-read tags'));
    await tester.pumpAndSettle();

    expect(reread, 7);
  });
}
