import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/src/rust/api/catalog.dart';
import 'package:olivier/src/rust/catalog/schema.dart';

// Exposes the global dbPath set in main() to the Riverpod graph.
// Overridden at the ProviderScope level in main.dart.
final dbPathProvider = Provider<String>((ref) => throw UnimplementedError(
      'dbPathProvider must be overridden in ProviderScope',
    ));

// --- Selected artist ---

class SelectedArtist extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? mbid) {
    state = mbid;
    // Selecting a new artist clears the album selection.
    ref.read(selectedAlbumProvider.notifier).clear();
  }
}

final selectedArtistProvider =
    NotifierProvider<SelectedArtist, String?>(SelectedArtist.new);

// --- Selected album ---

class SelectedAlbum extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? releaseMbid) {
    state = releaseMbid;
  }

  void clear() {
    state = null;
  }
}

final selectedAlbumProvider =
    NotifierProvider<SelectedAlbum, String?>(SelectedAlbum.new);

// --- Artists list ---

final artistsProvider = FutureProvider<List<Artist>>((ref) {
  final db = ref.watch(dbPathProvider);
  return listArtists(dbPath: db, after: null, limit: 1000);
});

// --- Albums for selected artist ---

final albumsProvider = FutureProvider<List<Album>>((ref) {
  final db = ref.watch(dbPathProvider);
  final artistMbid = ref.watch(selectedArtistProvider);
  if (artistMbid == null) return Future.value(<Album>[]);
  return listAlbums(dbPath: db, albumArtistMbid: artistMbid);
});

// --- Tracks for selected album ---

final tracksProvider = FutureProvider<List<Track>>((ref) {
  final db = ref.watch(dbPathProvider);
  final releaseMbid = ref.watch(selectedAlbumProvider);
  if (releaseMbid == null) return Future.value(<Track>[]);
  return listTracks(dbPath: db, releaseMbid: releaseMbid);
});
