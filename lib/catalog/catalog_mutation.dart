import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/state/providers.dart';

/// Runs a catalog-mutating context-menu action (remove / re-read tags) and
/// reconciles the UI afterward.
///
/// All four album/track remove + re-read handlers share the same shape:
/// capture the [ScaffoldMessenger] before the await, run [action], invalidate
/// the browse providers, clear the entity-level selection, reconcile a possibly
/// pruned artist selection, then show [successMessage]. On failure nothing is
/// invalidated and [failureMessage] is shown instead so an FFI/DB error never
/// escapes as an unhandled future.
///
/// [clearSelection] clears the column-specific selection (the album or track
/// notifier's `clear()`); the artist reconcile is common to every caller and is
/// handled here.
Future<void> runCatalogMutation(
  BuildContext context,
  WidgetRef ref, {
  required Future<void> Function() action,
  required void Function() clearSelection,
  required String successMessage,
  required String failureMessage,
}) async {
  // Capture before the await so we never touch BuildContext across an async
  // gap (no use_build_context_synchronously).
  final messenger = ScaffoldMessenger.of(context);
  // Only the seam call decides success/failure. Once it commits, the
  // post-mutation bookkeeping (invalidate, clear, reconcile) runs outside the
  // catch so a transient reconcile-read error can't relabel a committed
  // mutation as "Failed …".
  try {
    await action();
  } catch (_) {
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(failureMessage)));
    return;
  }
  ref.invalidate(artistsProvider);
  ref.invalidate(albumsProvider);
  ref.invalidate(tracksProvider);
  clearSelection();
  await _reconcileArtist(ref);
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(successMessage)));
}

/// If the mutation pruned the currently-selected artist (e.g. removing its last
/// album triggers the Rust prune_orphans cascade), the selection now points at
/// a deleted MBID. Mirror [ScanController._reconcileSelection]: drop the
/// dangling artist selection and the cached album object so the album/track
/// columns don't show an empty dead end.
Future<void> _reconcileArtist(WidgetRef ref) async {
  final selected = ref.read(selectedArtistProvider);
  if (selected == null) return;
  final artists = await ref.read(artistsProvider.future);
  if (!artists.any((a) => a.mbid == selected)) {
    ref.read(selectedArtistProvider.notifier).select(null);
    ref.read(selectedAlbumObjectProvider.notifier).select(null);
  }
}
