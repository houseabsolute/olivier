import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/state/browse_level.dart';
import 'package:olivier/state/providers.dart';

ProviderContainer _container() {
  final container = ProviderContainer(overrides: [
    dbPathProvider.overrideWithValue(':memory:'),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('derived level', () {
    test('no artist selected shows artists', () {
      final c = _container();
      expect(c.read(browseLevelProvider), BrowseLevel.artists);
    });

    test('an artist with no album shows that artist albums', () {
      final c = _container();
      c.read(selectedArtistProvider.notifier).select('A');
      expect(c.read(browseLevelProvider), BrowseLevel.albums);
    });

    test('an artist and album shows tracks', () {
      final c = _container();
      c.read(selectedArtistProvider.notifier).select('A');
      c.read(selectedAlbumProvider.notifier).select('R');
      expect(c.read(browseLevelProvider), BrowseLevel.tracks);
    });

    test('the search-hit shape lands on tracks', () {
      // selectHit sets artist, album and track in that order; the deepest
      // screen must follow without the search path knowing about layouts.
      final c = _container();
      c.read(selectedArtistProvider.notifier).select('A');
      c.read(selectedAlbumProvider.notifier).select('R');
      c.read(selectedTrackProvider.notifier).select(7);
      expect(c.read(browseLevelProvider), BrowseLevel.tracks);
    });
  });

  group('up()', () {
    test('from tracks clears only the album', () {
      final c = _container();
      c.read(selectedArtistProvider.notifier).select('A');
      c.read(selectedAlbumProvider.notifier).select('R');

      c.read(browseLevelProvider.notifier).up();

      expect(c.read(browseLevelProvider), BrowseLevel.albums);
      expect(c.read(selectedArtistProvider), 'A', reason: 'artist is kept');
      expect(c.read(selectedAlbumProvider), isNull);
    });

    test('from albums clears the artist', () {
      final c = _container();
      c.read(selectedArtistProvider.notifier).select('A');

      c.read(browseLevelProvider.notifier).up();

      expect(c.read(browseLevelProvider), BrowseLevel.artists);
      expect(c.read(selectedArtistProvider), isNull);
    });

    test('from artists is a no-op', () {
      final c = _container();
      c.read(browseLevelProvider.notifier).up();
      expect(c.read(browseLevelProvider), BrowseLevel.artists);
      expect(c.read(selectedArtistProvider), isNull);
    });

    test('walks all the way up one level at a time', () {
      final c = _container();
      c.read(selectedArtistProvider.notifier).select('A');
      c.read(selectedAlbumProvider.notifier).select('R');
      c.read(selectedTrackProvider.notifier).select(7);

      final notifier = c.read(browseLevelProvider.notifier);
      notifier.up();
      expect(c.read(browseLevelProvider), BrowseLevel.albums);
      notifier.up();
      expect(c.read(browseLevelProvider), BrowseLevel.artists);
    });
  });

  test('clearing the artist also clears the album', () {
    // SelectedArtist.select already cascades; clear() must match it, or the
    // level derivation would report albums for a null artist.
    final c = _container();
    c.read(selectedArtistProvider.notifier).select('A');
    c.read(selectedAlbumProvider.notifier).select('R');

    c.read(selectedArtistProvider.notifier).clear();

    expect(c.read(selectedArtistProvider), isNull);
    expect(c.read(selectedAlbumProvider), isNull);
  });
}
