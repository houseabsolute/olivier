import 'dart:async' show unawaited;

import 'package:flutter/widgets.dart' show FocusNode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/src/rust/api/activity.dart';
import 'package:olivier/src/rust/api/catalog.dart';
import 'package:olivier/src/rust/api/settings.dart' as rust_settings;
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/widgets/bilingual_text.dart';

// Exposes the global dbPath set in main() to the Riverpod graph.
// Overridden at the ProviderScope level in main.dart.
final dbPathProvider = Provider<String>((ref) => throw UnimplementedError(
      'dbPathProvider must be overridden in ProviderScope',
    ));

// Seam for the activity/error-log FFI, so the ErrorReporter can append an
// ERROR line without depending on the raw FFI directly.
typedef LogActivityFn = Future<void> Function(String category, String detail);

final logActivityFnProvider = Provider<LogActivityFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (category, detail) =>
      logActivity(dbPath: db, category: category, detail: detail);
});

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
    // A new album resets the track highlight (mirrors artist→album).
    ref.read(selectedTrackProvider.notifier).clear();
  }

  void clear() {
    state = null;
  }
}

final selectedAlbumProvider =
    NotifierProvider<SelectedAlbum, String?>(SelectedAlbum.new);

// --- Selected track ---

class SelectedTrack extends Notifier<int?> {
  @override
  int? build() => null;

  void select(int? trackId) {
    state = trackId;
  }

  void clear() {
    state = null;
  }
}

final selectedTrackProvider =
    NotifierProvider<SelectedTrack, int?>(SelectedTrack.new);

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

// --- Language-leads (A/B) display mode ---

// Indirection seams so the provider is unit-testable without the FFI.
typedef GetSettingFn = Future<String?> Function(String key);
typedef SetSettingFn = Future<void> Function(String key, String value);

final getSettingFnProvider = Provider<GetSettingFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (key) => rust_settings.getSetting(dbPath: db, key: key);
});

final setSettingFnProvider = Provider<SetSettingFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (key, value) =>
      rust_settings.setSetting(dbPath: db, key: key, value: value);
});

// Re-read one track's tags (re-homes it if the album/artist changed). Seam.
typedef RereadTrackTagsFn = Future<void> Function(int trackId);

final rereadTrackTagsFnProvider = Provider<RereadTrackTagsFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (trackId) => rereadTrackTags(dbPath: db, trackId: trackId);
});

// Re-read every track's tags for one album (re-homes any whose album changed). Seam.
typedef RereadAlbumTagsFn = Future<void> Function(String releaseMbid);

final rereadAlbumTagsFnProvider = Provider<RereadAlbumTagsFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (releaseMbid) => rereadAlbumTags(dbPath: db, releaseMbid: releaseMbid);
});

// Forget one album (release) from the catalog (file rows deleted + orphan
// prune). Seam so the column is testable without the live FFI.
typedef RemoveAlbumFn = Future<void> Function(String releaseMbid);

final removeAlbumFnProvider = Provider<RemoveAlbumFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (releaseMbid) => removeAlbum(dbPath: db, releaseMbid: releaseMbid);
});

// Forget one track from the catalog (file rows deleted + orphan prune). Seam.
typedef RemoveTrackFn = Future<void> Function(int trackId);

final removeTrackFnProvider = Provider<RemoveTrackFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (trackId) => removeTrack(dbPath: db, trackId: trackId);
});

// Loads one artist's raw reading/sort values for the "Set reading" dialog. Seam.
typedef ArtistReadingFn = Future<ArtistReading> Function(String mbid);

final artistReadingFnProvider = Provider<ArtistReadingFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (mbid) => artistReading(dbPath: db, mbid: mbid);
});

// Writes/clears one artist's reading + sort override. Seam.
typedef SetArtistReadingOverrideFn = Future<void> Function(
    String mbid, String? reading, String? sort);

final setArtistReadingOverrideFnProvider =
    Provider<SetArtistReadingOverrideFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (mbid, reading, sort) => setArtistReadingOverride(
      dbPath: db, mbid: mbid, reading: reading, sort: sort);
});

// Loads/writes one track's or release's reading + translation override. Seams.
typedef TitleOverrideFn = Future<TitleOverride> Function(String mbid);
typedef SetTitleOverrideFn = Future<void> Function(
    String mbid, String? translit, String? translate);

final trackTitleOverrideFnProvider = Provider<TitleOverrideFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (mbid) => trackTitleOverride(dbPath: db, recordingMbid: mbid);
});
final releaseTitleOverrideFnProvider = Provider<TitleOverrideFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (mbid) => releaseTitleOverride(dbPath: db, releaseMbid: mbid);
});
final setTrackTitleOverrideFnProvider = Provider<SetTitleOverrideFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (mbid, t, tr) => setTrackTitleOverride(
      dbPath: db, recordingMbid: mbid, translit: t, translate: tr);
});
final setReleaseTitleOverrideFnProvider = Provider<SetTitleOverrideFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (mbid, t, tr) => setReleaseTitleOverride(
      dbPath: db, releaseMbid: mbid, translit: t, translate: tr);
});

// --- Entity → paths FFI seams (overridable in tests) ---

final entityPathFnsProvider = Provider<EntityPathFns>((ref) {
  final db = ref.watch(dbPathProvider);
  return EntityPathFns(
    artistPaths: (mbid) =>
        trackPathsForArtist(dbPath: db, albumArtistMbid: mbid),
    albumPaths: (releaseMbid) =>
        albumFilePaths(dbPath: db, releaseMbid: releaseMbid),
    trackPath: (id) => trackPath(dbPath: db, trackId: id),
  );
});

/// The whole-library paths seam used by "Shuffle entire library".
typedef LibraryPathsFn = Future<List<String>> Function();

final libraryPathsFnProvider = Provider<LibraryPathsFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return () => trackPathsForLibrary(dbPath: db);
});

// --- Global search ---

class SearchQuery extends Notifier<String> {
  @override
  String build() => '';
  void set(String q) => state = q;
  void clear() => state = '';
}

final searchQueryProvider =
    NotifierProvider<SearchQuery, String>(SearchQuery.new);

class HighlightedSearchIndex extends Notifier<int> {
  @override
  int build() => -1;
  void set(int i) => state = i;
  void reset() => state = -1;
}

final highlightedSearchIndexProvider =
    NotifierProvider<HighlightedSearchIndex, int>(HighlightedSearchIndex.new);

// Shared focus node for the search field, so Ctrl-F can focus it from elsewhere.
final searchFocusNodeProvider = Provider<FocusNode>((ref) {
  final node = FocusNode(debugLabel: 'search');
  ref.onDispose(node.dispose);
  return node;
});

// Seam so searchResultsProvider is testable without the FFI.
typedef SearchCatalogFn = Future<SearchResults> Function(
    String query, int limit);

final searchCatalogFnProvider = Provider<SearchCatalogFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (query, limit) => searchCatalog(dbPath: db, q: query, limit: limit);
});

/// Per-group result cap. A group rendered at exactly this many rows shows a
/// "refine search" footer (there may be more matches).
const kSearchGroupLimit = 8;

final searchResultsProvider = FutureProvider<SearchResults>((ref) {
  final q = ref.watch(searchQueryProvider).trim();
  if (q.isEmpty) {
    return Future.value(
        const SearchResults(artists: [], albums: [], tracks: []));
  }
  final search = ref.watch(searchCatalogFnProvider);
  return search(q, kSearchGroupLimit);
});

const _languageLeadsKey = 'language_leads';

class LanguageLeadsNotifier extends Notifier<LanguageLeads> {
  // Tracks whether a user action has already set the value explicitly so that
  // a late-arriving hydrate() from build() does not stomp over it.
  bool _userSet = false;

  @override
  LanguageLeads build() {
    _userSet = false;
    // Default to A immediately; hydrate the stored value asynchronously.
    unawaited(hydrate());
    return LanguageLeads.a;
  }

  Future<void> hydrate() async {
    final raw = await ref.read(getSettingFnProvider)(_languageLeadsKey);
    // Only apply if the user hasn't toggled/set in the meantime.
    if (!_userSet) {
      state = _parse(raw);
    }
  }

  Future<void> set(LanguageLeads leads) async {
    _userSet = true;
    state = leads; // optimistic
    await ref.read(setSettingFnProvider)(
      _languageLeadsKey,
      leads == LanguageLeads.a ? 'A' : 'B',
    );
  }

  Future<void> toggle() =>
      set(state == LanguageLeads.a ? LanguageLeads.b : LanguageLeads.a);

  static LanguageLeads _parse(String? raw) =>
      raw == 'B' ? LanguageLeads.b : LanguageLeads.a;
}

final languageLeadsProvider =
    NotifierProvider<LanguageLeadsNotifier, LanguageLeads>(
  LanguageLeadsNotifier.new,
);
