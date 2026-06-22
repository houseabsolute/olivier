import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/search_results_panel.dart';

SearchResults _results() => SearchResults(
      artists: [
        const Artist(
            mbid: 'A',
            name: 'Shiina Ringo',
            sortName: 'Shiina, Ringo',
            transliteration: 'Shiina Ringo',
            nameOriginal: '椎名林檎'),
      ],
      albums: const [],
      tracks: [
        const SearchTrack(
            id: 7,
            title: 'Marunouchi Sadistic',
            titleTranslit: null,
            titleTranslate: null,
            albumArtist: 'Shiina Ringo',
            albumArtistOriginal: null,
            albumArtistReading: null,
            albumArtistMbid: 'A',
            releaseMbid: 'R'),
      ],
    );

void main() {
  testWidgets('renders grouped hits; tapping a track navigates the cascade',
      (tester) async {
    final container = ProviderContainer(overrides: [
      dbPathProvider.overrideWithValue(':memory:'),
      // languageLeadsProvider hydrates from a setting on build; stub the
      // seam so the panel's BilingualText rows don't hit the live FFI.
      getSettingFnProvider.overrideWithValue((key) async => null),
      searchCatalogFnProvider.overrideWithValue((q, limit) async => _results()),
    ]);
    addTearDown(container.dispose);
    container.read(searchQueryProvider.notifier).set('ringo');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: Stack(children: [SearchResultsPanel()])),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Artists'), findsOneWidget);
    expect(find.text('Tracks'), findsOneWidget);
    expect(find.text('Marunouchi Sadistic'), findsOneWidget);

    await tester.tap(find.text('Marunouchi Sadistic'));
    await tester.pump();

    expect(container.read(selectedArtistProvider), 'A');
    expect(container.read(selectedAlbumProvider), 'R');
    expect(container.read(selectedTrackProvider), 7);
    expect(container.read(searchQueryProvider), '');
  });

  testWidgets('hidden when query is blank', (tester) async {
    final container = ProviderContainer(
      overrides: [dbPathProvider.overrideWithValue(':memory:')],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: Stack(children: [SearchResultsPanel()])),
      ),
    ));
    await tester.pump();
    expect(find.text('Artists'), findsNothing);
  });
}
