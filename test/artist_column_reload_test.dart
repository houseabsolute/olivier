import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/album_column.dart';
import 'package:olivier/catalog/artist_column.dart';
import 'package:olivier/catalog/track_column.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

// The scan live-update feature invalidates the browse providers mid-scan.
// Riverpod's AsyncValue.when() keeps the previous value on screen during an
// invalidate / refresh by default (skipLoadingOnRefresh: true), so the browse
// columns must NOT flash a spinner while reloading over existing data. These
// regression tests lock that for all three columns — each fails if its column
// ever sets skipLoadingOnRefresh:false (or a future Riverpod flips the default).
void main() {
  // Builds the column under a container whose [provider] resolves once, then
  // hangs on the next build, and asserts: data shown + no spinner before AND
  // after a mid-scan invalidate of [provider].
  Future<void> expectNoFlashOnRefresh(
    WidgetTester tester, {
    required ProviderContainer container,
    required void Function() refresh,
    required Widget column,
    required String visibleText,
  }) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: column)),
    ));
    await tester.pumpAndSettle();
    expect(find.text(visibleText), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    refresh(); // mid-scan refresh
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason:
            'a mid-scan refresh must not flash a spinner over existing data');
    expect(find.text(visibleText), findsWidgets);
  }

  // A FutureProvider override that resolves to [value] on the first build and
  // never completes on later (post-invalidate) builds, so the provider sits in
  // refreshing-with-previous-value.
  Future<List<T>> Function(Ref) firstThenHang<T>(List<T> value) {
    var phase = 0;
    return (ref) {
      phase++;
      return phase == 1 ? Future.value(value) : Completer<List<T>>().future;
    };
  }

  testWidgets('artist column keeps its list during a mid-scan refresh',
      (tester) async {
    final container = ProviderContainer(overrides: [
      getSettingFnProvider.overrideWithValue((k) async => null),
      artistsProvider.overrideWith(firstThenHang(
          [Artist(mbid: 'a1', name: 'Alpha', sortName: 'Alpha')])),
    ]);
    addTearDown(container.dispose);
    await expectNoFlashOnRefresh(tester,
        container: container,
        refresh: () => container.invalidate(artistsProvider),
        column: const ArtistColumn(),
        visibleText: 'Alpha');
  });

  testWidgets('album column keeps its list during a mid-scan refresh',
      (tester) async {
    final container = ProviderContainer(overrides: [
      getSettingFnProvider.overrideWithValue((k) async => null),
      albumsProvider.overrideWith(firstThenHang([
        Album(
            releaseMbid: 'r1', title: 'AlbumX', albumArtist: 'Art', addedAt: 0)
      ])),
    ]);
    addTearDown(container.dispose);
    await expectNoFlashOnRefresh(tester,
        container: container,
        refresh: () => container.invalidate(albumsProvider),
        column: const AlbumColumn(),
        visibleText: 'AlbumX');
  });

  testWidgets('track column keeps its list during a mid-scan refresh',
      (tester) async {
    final container = ProviderContainer(overrides: [
      getSettingFnProvider.overrideWithValue((k) async => null),
      tracksProvider.overrideWith(firstThenHang(
          [Track(id: 1, disc: 1, position: 1, title: 'TrackX', addedAt: 0)])),
    ]);
    addTearDown(container.dispose);
    await expectNoFlashOnRefresh(tester,
        container: container,
        refresh: () => container.invalidate(tracksProvider),
        column: const TrackColumn(),
        visibleText: 'TrackX');
  });
}
