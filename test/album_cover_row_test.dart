import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/album_column.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/cover_providers.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/album_cover.dart';

const _album = Album(
  releaseMbid: 'rel-1',
  title: 'Album One',
  albumArtist: 'Artist',
  addedAt: 0,
);

void main() {
  testWidgets('each album row renders an AlbumCover', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        albumsProvider.overrideWith((ref) => [_album]),
        coverForReleaseFnProvider.overrideWithValue((_) async => null),
      ],
      child: const MaterialApp(home: Scaffold(body: AlbumColumn())),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.byType(AlbumCover), findsOneWidget);
  });
}
