import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/browser_page.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';
import 'package:olivier/state/scan_controller.dart';
import 'package:olivier/widgets/resizable_split.dart';

const _artist = Artist(
  mbid: 'a1',
  name: 'Ringo Sheena',
  sortName: 'Sheena, Ringo',
  transliteration: 'Ringo Sheena',
  nameOriginal: '椎名林檎',
);

const _album = Album(
  releaseMbid: 'r1',
  title: '無罪モラトリアム',
  albumArtist: '椎名林檎',
  originalYear: '1999',
  titleTranslit: 'Muzai Moratorium',
  titleTranslate: 'Innocence Moratorium',
  addedAt: 0,
);

final _track = Track(
  id: 1,
  disc: 1,
  position: 1,
  title: '歌舞伎町の女王',
  addedAt: 0,
  lengthMs: BigInt.from(258000),
  titleTranslit: 'Kabukicho no Joo',
  titleTranslate: 'Queen of Kabuki-cho',
);

/// Returns an empty [QueueView] without touching FFI or [queueControllerProvider].
class _EmptyQueue extends QueueNotifier {
  @override
  Future<QueueView> build() async => QueueView.empty;
}

/// A [ScanController] whose [loadRoots] is a no-op, so the page's post-frame
/// hydrate never reaches the real `listRoots` FFI in a headless test.
class _StubScanController extends ScanController {
  @override
  ScanState build() => const ScanState();

  @override
  Future<void> loadRoots() async {}
}

Widget _page(double scale) {
  return ProviderScope(
    overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      artistsProvider.overrideWith((ref) => [_artist]),
      albumsProvider.overrideWith((ref) => [_album]),
      tracksProvider.overrideWith((ref) => [_track]),
      // Pre-select so the album/track columns render content (not their
      // "Select an artist/album" placeholders).
      selectedArtistProvider
          .overrideWith(() => _PreselectedArtist(_artist.mbid)),
      selectedAlbumProvider
          .overrideWith(() => _PreselectedAlbum(_album.releaseMbid)),
      scanControllerProvider.overrideWith(_StubScanController.new),
      queueProvider.overrideWith(_EmptyQueue.new),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          // Inject a trivial now-playing bar so the live global audioHandler
          // is never referenced.
          child: const BrowserPage(
            nowPlaying: SizedBox(height: 56, child: Text('stub-now-playing')),
            topControls: SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
}

class _PreselectedArtist extends SelectedArtist {
  _PreselectedArtist(this._mbid);
  final String _mbid;
  @override
  String? build() => _mbid;
}

class _PreselectedAlbum extends SelectedAlbum {
  _PreselectedAlbum(this._mbid);
  final String _mbid;
  @override
  String? build() => _mbid;
}

void main() {
  for (final scale in const [1.0, 1.3]) {
    testWidgets(
        'BrowserPage renders 2-pane + stacked columns + queue panel '
        'without overflow at ${scale}x', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_page(scale));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);

      // Left pane: artist. Right pane stacks album over track.
      expect(find.text('Ringo Sheena'), findsOneWidget);
      expect(find.text('無罪モラトリアム'), findsOneWidget);
      expect(find.text('歌舞伎町の女王'), findsOneWidget);

      // The right pane stacks album over track as a nested vertical split,
      // so the page renders two ResizableSplits (artist|right and album|track).
      expect(find.byType(ResizableSplit), findsNWidgets(2));

      // The collapsed queue-panel header is present, above the now-playing bar.
      expect(find.textContaining('0 tracks'), findsOneWidget);
      expect(find.text('stub-now-playing'), findsOneWidget);
    });
  }
}
