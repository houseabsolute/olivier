import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/albums_by_added_page.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

const _newest = Album(
  releaseMbid: 'rel-new',
  title: 'Newest Album',
  albumArtist: 'Artist B',
  albumArtistMbid: 'm-b',
  addedAt: 1700000000,
);
const _oldest = Album(
  releaseMbid: 'rel-old',
  title: 'Oldest Album',
  albumArtist: 'Artist A',
  albumArtistMbid: 'm-a',
  addedAt: 1000000000,
);

/// Records the direction each query was made with, and answers in that order —
/// the ordering itself is SQL's job (covered by the Rust test), so what matters
/// here is that the toggle re-queries the other way and renders the result.
class _Recorder {
  final directions = <bool>[];

  Future<List<Album>> call(bool newestFirst) async {
    directions.add(newestFirst);
    return newestFirst ? [_newest, _oldest] : [_oldest, _newest];
  }
}

Widget _app(_Recorder recorder) {
  return ProviderScope(
    overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      albumsByAddedFnProvider.overrideWithValue(recorder.call),
    ],
    child: const MaterialApp(home: AlbumsByAddedPage()),
  );
}

/// Top-to-bottom order of the album titles as laid out.
List<String> _titleOrder(WidgetTester tester) {
  final titles = ['Newest Album', 'Oldest Album']..sort((a, b) => tester
      .getTopLeft(find.text(a))
      .dy
      .compareTo(tester.getTopLeft(find.text(b)).dy));
  return titles;
}

void main() {
  testWidgets('lists newest first, with each album\'s date added',
      (tester) async {
    final recorder = _Recorder();
    await tester.pumpWidget(_app(recorder));
    await tester.pumpAndSettle();

    expect(recorder.directions, [true], reason: 'newest first by default');
    expect(_titleOrder(tester), ['Newest Album', 'Oldest Album']);
    // 1700000000 / 1000000000 rendered as local YYYY-MM-DD.
    expect(find.textContaining('-'), findsWidgets);
    expect(find.text('Artist A'), findsOneWidget);
    expect(find.text('Artist B'), findsOneWidget);
  });

  testWidgets('the direction control flips the order', (tester) async {
    final recorder = _Recorder();
    await tester.pumpWidget(_app(recorder));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Show oldest first'));
    await tester.pumpAndSettle();

    expect(recorder.directions, [true, false]);
    expect(_titleOrder(tester), ['Oldest Album', 'Newest Album']);
    // The control now offers the way back.
    expect(find.byTooltip('Show newest first'), findsOneWidget);
  });

  testWidgets('tapping an album selects it for the browse cascade',
      (tester) async {
    final recorder = _Recorder();
    await tester.pumpWidget(_app(recorder));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AlbumsByAddedPage)),
    );

    await tester.tap(find.text('Oldest Album'));
    await tester.pumpAndSettle();

    expect(container.read(selectedArtistProvider), 'm-a');
    expect(container.read(selectedAlbumProvider), 'rel-old');
  });
}
