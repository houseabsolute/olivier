import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/browser_page.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/browse_level.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';
import 'package:olivier/state/scan_controller.dart';
import 'package:olivier/widgets/resizable_split.dart';

import 'support/fake_queue_player.dart';

const _artist = Artist(
  mbid: 'a1',
  name: 'Ringo Sheena',
  sortName: 'Sheena, Ringo',
  transliteration: 'Ringo Sheena',
  nameOriginal: null,
);

const _album = Album(
  releaseMbid: 'r1',
  title: 'Muzai Moratorium',
  albumArtist: 'Ringo Sheena',
  originalYear: '1999',
  titleTranslit: null,
  titleTranslate: null,
  addedAt: 0,
);

final _track = Track(
  id: 1,
  disc: 1,
  position: 1,
  title: 'Kabukicho no Joo',
  addedAt: 0,
  lengthMs: BigInt.from(258000),
  titleTranslit: null,
  titleTranslate: null,
);

class _EmptyQueue extends QueueNotifier {
  @override
  Future<QueueView> build() async => QueueView.empty;
}

class _StubScanController extends ScanController {
  @override
  ScanState build() => const ScanState();

  @override
  Future<void> loadRoots() async {}
}

late ProviderContainer container;

Widget _page() {
  container = ProviderContainer(overrides: [
    getSettingFnProvider.overrideWithValue((key) async => null),
    setSettingFnProvider.overrideWithValue((key, value) async {}),
    artistsProvider.overrideWith((ref) => [_artist]),
    albumsProvider.overrideWith((ref) => [_album]),
    tracksProvider.overrideWith((ref) => [_track]),
    scanControllerProvider.overrideWith(_StubScanController.new),
    queueProvider.overrideWith(_EmptyQueue.new),
    // QueuePanel reaches for the playback controller; a controller over a fake
    // player keeps the full-screen queue off the FFI.
    queueControllerProvider.overrideWithValue(
      QueueController.withPlayer(FakeQueuePlayer(),
          dbPath: ':memory:', saveQueue: (_) async {}),
    ),
  ]);
  addTearDown(container.dispose);
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: BrowserPage(
        nowPlaying: SizedBox(height: 56, child: Text('stub-now-playing')),
        topControls: SizedBox.shrink(),
      ),
    ),
  );
}

Future<void> _pumpNarrow(WidgetTester tester,
    {Size size = const Size(400, 800)}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_page());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('drills down artists → albums → tracks', (tester) async {
    await _pumpNarrow(tester);

    // Level 1: artists only, no cascade, no back button.
    expect(find.byType(ResizableSplit), findsNothing);
    expect(find.text('Ringo Sheena'), findsOneWidget);
    expect(find.textContaining('Muzai Moratorium'), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    expect(find.text('Artists'), findsOneWidget);

    await tester.tap(find.text('Ringo Sheena'));
    await tester.pumpAndSettle();

    // Level 2: that artist's albums, titled with the artist's name. The album
    // row carries its release year, so match on the title alone.
    expect(find.text('Muzai Moratorium (1999)'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Ringo Sheena'), findsOneWidget);

    await tester.tap(find.text('Muzai Moratorium (1999)'));
    await tester.pumpAndSettle();

    // Level 3: that album's tracks, titled with the album.
    expect(find.text('Kabukicho no Joo'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Muzai Moratorium'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('back walks up one level at a time', (tester) async {
    await _pumpNarrow(tester);
    container.read(selectedArtistProvider.notifier).select('a1');
    container.read(selectedAlbumProvider.notifier).select('r1');
    await tester.pumpAndSettle();
    expect(container.read(browseLevelProvider), BrowseLevel.tracks);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(container.read(browseLevelProvider), BrowseLevel.albums);
    expect(find.textContaining('Muzai Moratorium'), findsWidgets);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(container.read(browseLevelProvider), BrowseLevel.artists);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
  });

  testWidgets('a search hit lands on the deepest screen', (tester) async {
    await _pumpNarrow(tester);

    // The shape selectHit produces: artist, then album, then track.
    container.read(selectedArtistProvider.notifier).select('a1');
    container.read(selectedAlbumProvider.notifier).select('r1');
    container.read(selectedTrackProvider.notifier).select(1);
    await tester.pumpAndSettle();

    expect(find.text('Kabukicho no Joo'), findsOneWidget);
  });

  testWidgets('the queue opens full screen and backs out', (tester) async {
    await _pumpNarrow(tester);

    // No collapsed queue header competing for space at the browse levels.
    expect(find.textContaining('0 tracks'), findsNothing);

    await tester.tap(find.byIcon(Icons.queue_music));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Queue'), findsOneWidget);
    expect(find.text('Ringo Sheena'), findsNothing);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('Ringo Sheena'), findsOneWidget);
  });

  testWidgets('the now-playing bar stays pinned at every level',
      (tester) async {
    await _pumpNarrow(tester);
    expect(find.text('stub-now-playing'), findsOneWidget);

    container.read(selectedArtistProvider.notifier).select('a1');
    await tester.pumpAndSettle();
    expect(find.text('stub-now-playing'), findsOneWidget);

    container.read(selectedAlbumProvider.notifier).select('r1');
    await tester.pumpAndSettle();
    expect(find.text('stub-now-playing'), findsOneWidget);
  });

  group('breakpoint', () {
    testWidgets('599 is narrow', (tester) async {
      await _pumpNarrow(tester, size: const Size(599, 800));
      expect(find.byType(ResizableSplit), findsNothing);
    });

    testWidgets('601 is the cascade', (tester) async {
      await _pumpNarrow(tester, size: const Size(601, 800));
      expect(find.byType(ResizableSplit), findsNWidgets(2));
    });
  });
}
