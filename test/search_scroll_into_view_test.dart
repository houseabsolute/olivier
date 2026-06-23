import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/artist_column.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

void main() {
  testWidgets('artist column scrolls a deep selected artist into view',
      (tester) async {
    final artists = [
      for (var i = 0; i < 200; i++)
        Artist(
            mbid: 'A$i',
            name: 'Artist $i',
            sortName: 'Artist $i',
            transliteration: null,
            nameOriginal: null),
    ];
    final container = ProviderContainer(overrides: [
      dbPathProvider.overrideWithValue(':memory:'),
      getSettingFnProvider.overrideWithValue((key) async => null),
      artistsProvider.overrideWith((ref) async => artists),
    ]);
    addTearDown(container.dispose);
    container.read(selectedArtistProvider.notifier).select('A180');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
            body: SizedBox(width: 300, height: 600, child: ArtistColumn())),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Artist 180'), findsOneWidget);
  });

  testWidgets('selecting an already-visible artist does not scroll the list',
      (tester) async {
    final artists = [
      for (var i = 0; i < 200; i++)
        Artist(
            mbid: 'A$i',
            name: 'Artist $i',
            sortName: 'Artist $i',
            transliteration: null,
            nameOriginal: null),
    ];
    final container = ProviderContainer(overrides: [
      dbPathProvider.overrideWithValue(':memory:'),
      getSettingFnProvider.overrideWithValue((key) async => null),
      artistsProvider.overrideWith((ref) async => artists),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
            body: SizedBox(width: 300, height: 600, child: ArtistColumn())),
      ),
    ));
    await tester.pumpAndSettle();

    // At offset 0, "Artist 2" is on-screen. Selecting it (as a normal click
    // would) must NOT yank the list — the visibility guard leaves it put.
    container.read(selectedArtistProvider.notifier).select('A2');
    await tester.pumpAndSettle();
    final position =
        tester.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(position.pixels, 0.0);
  });
}
