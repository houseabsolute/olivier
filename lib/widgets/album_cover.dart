import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/state/cover_providers.dart';

/// A square album-cover image for a release MBID. Shows the resolved cover when
/// available, otherwise a muted placeholder (while loading or when there is no
/// art). Resolved via [albumCoverProvider] (embedded -> CAA -> none).
class AlbumCover extends ConsumerWidget {
  const AlbumCover({super.key, required this.releaseMbid, required this.size});

  final String releaseMbid;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = ref.watch(albumCoverProvider(releaseMbid)).value;
    return CoverImage(path: path, size: size);
  }
}

/// A square cover for an audio file path (used for the now-playing track).
class PathCover extends ConsumerWidget {
  const PathCover({super.key, required this.filePath, required this.size});

  final String filePath;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = ref.watch(pathCoverProvider(filePath)).value;
    return CoverImage(path: path, size: size);
  }
}

/// Renders a cached cover file as a clipped square, or a muted placeholder when
/// [path] is null or the file fails to decode. Shared by [AlbumCover]/[PathCover].
class CoverImage extends StatelessWidget {
  const CoverImage({super.key, required this.path, required this.size});

  final String? path;
  final double size;

  Widget _placeholder(ColorScheme scheme, BorderRadius radius) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: radius,
        ),
        child: Icon(Icons.album, size: size * 0.6, color: scheme.outline),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(4);
    if (path == null) {
      return _placeholder(scheme, radius);
    }
    return ClipRRect(
      borderRadius: radius,
      child: Image.file(
        File(path!),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * 2).round(),
        gaplessPlayback: true,
        errorBuilder: (context, _, __) => _placeholder(scheme, radius),
      ),
    );
  }
}
