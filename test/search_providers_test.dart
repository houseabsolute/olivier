import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/search.dart';

void main() {
  test('searchResultsProvider is empty for a blank query, calls seam otherwise',
      () async {
    var calls = 0;
    final container = ProviderContainer(overrides: [
      dbPathProvider.overrideWithValue(':memory:'),
      searchCatalogFnProvider.overrideWithValue((q, limit) async {
        calls++;
        return SearchResults(
          artists: [
            const Artist(
                mbid: 'A',
                name: 'Shiina Ringo',
                sortName: 'Shiina, Ringo',
                transliteration: 'Shiina Ringo',
                nameOriginal: '椎名林檎'),
          ],
          albums: const [],
          tracks: const [],
        );
      }),
    ]);
    addTearDown(container.dispose);

    expect(
        (await container.read(searchResultsProvider.future)).artists, isEmpty);
    expect(calls, 0);

    container.read(searchQueryProvider.notifier).set('ringo');
    final r = await container.read(searchResultsProvider.future);
    expect(r.artists.single.mbid, 'A');
    expect(calls, 1);
  });

  test('flattenHits orders artists, then albums, then tracks', () {
    final results = SearchResults(
      artists: [
        const Artist(
            mbid: 'A',
            name: 'x',
            sortName: 'x',
            transliteration: null,
            nameOriginal: null),
      ],
      albums: [
        const Album(
            releaseMbid: 'R',
            title: 'Alb',
            albumArtist: 'x',
            originalYear: null,
            reissueYear: null,
            titleTranslit: null,
            titleTranslate: null,
            addedAt: 0,
            albumArtistOriginal: null,
            albumArtistReading: null,
            albumArtistMbid: 'A'),
      ],
      tracks: [
        const SearchTrack(
            id: 1,
            title: 'T',
            titleTranslit: null,
            titleTranslate: null,
            albumArtist: null,
            albumArtistOriginal: null,
            albumArtistReading: null,
            albumArtistMbid: 'A',
            releaseMbid: 'R'),
      ],
    );
    final hits = flattenHits(results);
    expect(hits.map((h) => h.runtimeType).toList(),
        [ArtistHit, AlbumHit, TrackHit]);
  });
}
