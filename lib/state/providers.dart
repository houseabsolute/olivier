import 'dart:async' show unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/src/rust/api/catalog.dart';
import 'package:olivier/src/rust/api/settings.dart' as rust_settings;
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/widgets/bilingual_text.dart';

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

// Resolves one track's single play path (MIN path); seam for testability.
typedef TrackPathFn = Future<String?> Function(int trackId);

final trackPathFnProvider = Provider<TrackPathFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (trackId) => trackPath(dbPath: db, trackId: trackId);
});

// Resolves an album's file paths (one per track, disc/position order); seam.
typedef AlbumFilePathsFn = Future<List<String>> Function(String releaseMbid);

final albumFilePathsFnProvider = Provider<AlbumFilePathsFn>((ref) {
  final db = ref.watch(dbPathProvider);
  return (releaseMbid) => albumFilePaths(dbPath: db, releaseMbid: releaseMbid);
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
