import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/state/providers.dart';

/// Which level of the browse cascade the narrow layout is showing.
enum BrowseLevel { artists, albums, tracks }

/// Below [kNarrowBrowseWidth] the artist | album / track cascade can't fit —
/// it needs ~548px for its own minimums alone — so the browse UI shows one
/// level at a time instead. 600 is Material's compact/expanded boundary.
const double kNarrowBrowseWidth = 600;

/// The current level, *derived* from the selection rather than tracked
/// separately.
///
/// A navigator stack or a stored index would be a second source of truth that
/// could disagree with the selection providers — which are mutated from outside
/// the browse UI, notably by search. Deriving it means selecting a search hit
/// (artist + album + track, see `selectHit`) lands on the track list with no
/// layout-specific code in the search path, and "back" is just clearing one
/// level.
class BrowseLevelNotifier extends Notifier<BrowseLevel> {
  @override
  BrowseLevel build() {
    if (ref.watch(selectedArtistProvider) == null) return BrowseLevel.artists;
    if (ref.watch(selectedAlbumProvider) == null) return BrowseLevel.albums;
    return BrowseLevel.tracks;
  }

  /// Go up one level. The notifiers' own cascade does the rest: clearing the
  /// artist clears the album, clearing the album clears the track highlight.
  /// At [BrowseLevel.artists] there is nowhere to go — the caller decides
  /// whether that means leaving the app.
  void up() {
    switch (state) {
      case BrowseLevel.tracks:
        ref.read(selectedAlbumProvider.notifier).clear();
      case BrowseLevel.albums:
        ref.read(selectedArtistProvider.notifier).clear();
      case BrowseLevel.artists:
        break;
    }
  }
}

final browseLevelProvider =
    NotifierProvider<BrowseLevelNotifier, BrowseLevel>(BrowseLevelNotifier.new);
