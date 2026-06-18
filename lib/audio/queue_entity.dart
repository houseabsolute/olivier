import 'package:flutter/foundation.dart';

/// A draggable / right-clickable reference to a browse entity that can be
/// resolved to a list of track file paths and appended to the queue.
@immutable
sealed class QueueEntityRef {
  const QueueEntityRef();
  const factory QueueEntityRef.artist(String albumArtistMbid) = ArtistEntity;
  const factory QueueEntityRef.album(String releaseMbid) = AlbumEntity;
  const factory QueueEntityRef.track(int trackId) = TrackEntity;
}

class ArtistEntity extends QueueEntityRef {
  const ArtistEntity(this.albumArtistMbid);
  final String albumArtistMbid;
}

class AlbumEntity extends QueueEntityRef {
  const AlbumEntity(this.releaseMbid);
  final String releaseMbid;
}

class TrackEntity extends QueueEntityRef {
  const TrackEntity(this.trackId);
  final int trackId;
}

/// The FFI seams needed to turn an entity into paths. Bundled so widget tests
/// can supply fakes without touching the real bridge.
class EntityPathFns {
  const EntityPathFns({
    required this.artistPaths,
    required this.albumPaths,
    required this.trackPath,
  });

  final Future<List<String>> Function(String albumArtistMbid) artistPaths;
  final Future<List<String>> Function(String releaseMbid) albumPaths;
  final Future<String?> Function(int trackId) trackPath;
}

/// Resolve one entity to the ordered list of file paths it contributes.
Future<List<String>> resolveEntityPaths(
  QueueEntityRef entity,
  EntityPathFns fns,
) async {
  switch (entity) {
    case ArtistEntity(:final albumArtistMbid):
      return fns.artistPaths(albumArtistMbid);
    case AlbumEntity(:final releaseMbid):
      return fns.albumPaths(releaseMbid);
    case TrackEntity(:final trackId):
      final p = await fns.trackPath(trackId);
      return p == null ? <String>[] : <String>[p];
  }
}
