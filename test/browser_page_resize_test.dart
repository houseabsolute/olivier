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
  testWidgets('renders two MultiSplitViews (artist|right and album|track)',
      (tester) async {
    final saved = <String, String>{};
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((_) async => null),
        setSettingFnProvider.overrideWithValue((k, v) async => saved[k] = v),
        artistsProvider.overrideWith((ref) => [_artist]),
        albumsProvider.overrideWith((ref) => [_album]),
        tracksProvider.overrideWith((ref) => [_track]),
        selectedArtistProvider
            .overrideWith(() => _PreselectedArtist(_artist.mbid)),
        selectedAlbumProvider
            .overrideWith(() => _PreselectedAlbum(_album.releaseMbid)),
        scanControllerProvider.overrideWith(_StubScanController.new),
        queueProvider.overrideWith(_EmptyQueue.new),
      ],
      child: const MaterialApp(
        home: BrowserPage(
          nowPlaying: SizedBox.shrink(),
          topControls: SizedBox.shrink(),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.byType(ResizableSplit), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
