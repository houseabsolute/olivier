import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/src/rust/api/enrich.dart';
import 'package:olivier/src/rust/enrich/progress.dart';
import 'package:olivier/state/providers.dart';

/// Sentinel so [EnrichState.copyWith] can clear [lastError] to null.
const Object _unset = Object();

/// Snapshot of the MusicBrainz enrichment subsystem, watched by the UI.
class EnrichState {
  /// An enrichment pass is in progress.
  final bool running;

  /// Live progress: entities (artists/releases) processed of the total.
  final int entitiesDone;
  final int entitiesTotal;

  /// The entity currently being fetched/processed.
  final String current;

  /// Error from the last pass, or null.
  final String? lastError;

  const EnrichState({
    this.running = false,
    this.entitiesDone = 0,
    this.entitiesTotal = 0,
    this.current = '',
    this.lastError,
  });

  EnrichState copyWith({
    bool? running,
    int? entitiesDone,
    int? entitiesTotal,
    String? current,
    Object? lastError = _unset,
  }) {
    return EnrichState(
      running: running ?? this.running,
      entitiesDone: entitiesDone ?? this.entitiesDone,
      entitiesTotal: entitiesTotal ?? this.entitiesTotal,
      current: current ?? this.current,
      lastError:
          identical(lastError, _unset) ? this.lastError : lastError as String?,
    );
  }
}

typedef EnrichEntityFn = Stream<EnrichProgress> Function(String mbid);

final enrichArtistFnProvider = Provider<EnrichEntityFn>((ref) {
  final db = ref.read(dbPathProvider);
  return (mbid) => enrichArtist(dbPath: db, artistMbid: mbid);
});
final enrichAlbumFnProvider = Provider<EnrichEntityFn>((ref) {
  final db = ref.read(dbPathProvider);
  return (mbid) => enrichAlbum(dbPath: db, releaseMbid: mbid);
});

/// Drives MusicBrainz enrichment (fills artist transliterations, title
/// translations, and original/reissue dates). `enrich(force: false)` is the
/// resumable path auto-run after a scan and from the Settings "Enrich library"
/// action (skips already-enriched files + cached entities);
/// `refreshFromMusicBrainz()` empties the cache and refetches from the network.
/// `enrichArtist(mbid)` / `enrichAlbum(mbid)` re-fetch a single artist/album
/// (scoped MusicBrainz cache-clear + constrained re-enrich), sharing the same
/// single-flight guard.
/// Single-flight; streams progress; refreshes the browse columns when new
/// bilingual data lands.
class EnrichController extends Notifier<EnrichState> {
  bool _running = false;
  bool _disposed = false;

  @override
  EnrichState build() {
    ref.onDispose(() => _disposed = true);
    return const EnrichState();
  }

  Future<void> enrich({bool force = false, bool clearCache = false}) async {
    if (_running) return;
    _running = true;
    final db = ref.read(dbPathProvider);
    if (!_disposed) {
      state = state.copyWith(
        running: true,
        entitiesDone: 0,
        entitiesTotal: 0,
        current: '',
        lastError: null,
      );
    }
    try {
      if (clearCache) {
        await clearMbCache(dbPath: db);
        if (_disposed) return;
      }
      await for (final p in enrichLibrary(dbPath: db, force: force)) {
        if (_disposed) return;
        state = state.copyWith(
          entitiesDone: p.entitiesDone.toInt(),
          entitiesTotal: p.entitiesTotal.toInt(),
          current: p.current,
        );
        if (p.done) break;
      }
    } catch (e) {
      if (!_disposed) state = state.copyWith(lastError: '$e');
    } finally {
      _running = false;
      if (!_disposed) {
        state = state.copyWith(running: false);
        // New transliterations / title alts may have landed — refresh columns.
        ref.invalidate(artistsProvider);
        ref.invalidate(albumsProvider);
        ref.invalidate(tracksProvider);
      }
    }
  }

  /// Empty the MB response cache, then re-enrich everything from the network.
  /// A single `enrich` call (one `_running` claim) so a concurrent auto-enrich
  /// can't slip in between the cache wipe and the refetch.
  Future<void> refreshFromMusicBrainz() =>
      enrich(force: true, clearCache: true);

  Future<void> enrichArtist(String mbid) =>
      _runEntity(ref.read(enrichArtistFnProvider), mbid);
  Future<void> enrichAlbum(String mbid) =>
      _runEntity(ref.read(enrichAlbumFnProvider), mbid);

  Future<void> _runEntity(EnrichEntityFn fn, String mbid) async {
    if (_running) return;
    _running = true;
    if (!_disposed) {
      state = state.copyWith(
          running: true,
          entitiesDone: 0,
          entitiesTotal: 0,
          current: '',
          lastError: null);
    }
    try {
      await for (final p in fn(mbid)) {
        if (_disposed) return;
        state = state.copyWith(
            entitiesDone: p.entitiesDone.toInt(),
            entitiesTotal: p.entitiesTotal.toInt(),
            current: p.current);
        if (p.done) break;
      }
    } catch (e) {
      if (!_disposed) state = state.copyWith(lastError: '$e');
    } finally {
      _running = false;
      if (!_disposed) {
        state = state.copyWith(running: false);
        ref.invalidate(artistsProvider);
        ref.invalidate(albumsProvider);
        ref.invalidate(tracksProvider);
      }
    }
  }
}

final enrichControllerProvider =
    NotifierProvider<EnrichController, EnrichState>(EnrichController.new);
