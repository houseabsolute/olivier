import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

/// A single flattened search hit, used for keyboard navigation + selection.
sealed class SearchHit {
  const SearchHit();
}

class ArtistHit extends SearchHit {
  const ArtistHit(this.artist);
  final Artist artist;
}

class AlbumHit extends SearchHit {
  const AlbumHit(this.album);
  final Album album;
}

class TrackHit extends SearchHit {
  const TrackHit(this.track);
  final SearchTrack track;
}

/// Flatten grouped results into one ordered list: artists, then albums, then
/// tracks — matching the on-screen group order so a keyboard index lines up.
List<SearchHit> flattenHits(SearchResults r) => [
      ...r.artists.map(ArtistHit.new),
      ...r.albums.map(AlbumHit.new),
      ...r.tracks.map(TrackHit.new),
    ];

/// Navigate the browse cascade to [hit] (reveal + highlight), then clear the
/// query so the overlay closes. Order matters: selecting an artist clears the
/// album selection and selecting an album clears the track selection, so the
/// track is selected last.
void selectHit(WidgetRef ref, SearchHit hit) {
  switch (hit) {
    case ArtistHit(:final artist):
      ref.read(selectedArtistProvider.notifier).select(artist.mbid);
    case AlbumHit(:final album):
      ref.read(selectedArtistProvider.notifier).select(album.albumArtistMbid);
      ref.read(selectedAlbumProvider.notifier).select(album.releaseMbid);
    case TrackHit(:final track):
      ref.read(selectedArtistProvider.notifier).select(track.albumArtistMbid);
      ref.read(selectedAlbumProvider.notifier).select(track.releaseMbid);
      ref.read(selectedTrackProvider.notifier).select(track.id);
  }
  ref.read(searchQueryProvider.notifier).clear();
  ref.read(highlightedSearchIndexProvider.notifier).reset();
}
