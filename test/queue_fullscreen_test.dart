import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/artist_column.dart';
import 'package:olivier/catalog/browser_page.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/cover_providers.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';
import 'package:olivier/state/scan_controller.dart';

import 'support/fake_queue_player.dart';

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

QueueTrack _qt(String path, String title) => QueueTrack(
      path: path,
      title: title,
      album: '',
      addedAt: 0,
      lastPlayed: null,
      titleTranslit: null,
      titleTranslate: null,
    );

class _FakeQueue extends QueueNotifier {
  _FakeQueue(this._view);
  final QueueView _view;
  @override
  Future<QueueView> build() async => _view;
}

void main() {
  testWidgets(
      'collapsed: ArtistColumn is visible; expanded: browse is hidden and tracks show',
      (tester) async {
    final player = FakeQueuePlayer();
    final qc = QueueController.withPlayer(
      player,
      dbPath: ':memory:',
      saveQueue: (_) async {},
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((_) async => null),
        setSettingFnProvider.overrideWithValue((k, v) async {}),
        artistsProvider.overrideWith((ref) => [_artist]),
        albumsProvider.overrideWith((ref) => [_album]),
        tracksProvider.overrideWith((ref) => [_track]),
        selectedArtistProvider
            .overrideWith(() => _PreselectedArtist(_artist.mbid)),
        selectedAlbumProvider
            .overrideWith(() => _PreselectedAlbum(_album.releaseMbid)),
        scanControllerProvider.overrideWith(_StubScanController.new),
        coverForPathFnProvider.overrideWithValue((_) async => null),
        queueControllerProvider.overrideWithValue(qc),
        shuffleAllTargetProvider.overrideWithValue(qc),
        queueProvider.overrideWith(() => _FakeQueue(QueueView(
              tracks: [
                _qt('/m/a.flac', 'Track A'),
                _qt('/m/b.flac', 'Track B'),
              ],
              currentIndex: 0,
              shuffled: false,
            ))),
      ],
      child: const MaterialApp(
        home: BrowserPage(nowPlaying: SizedBox.shrink()),
      ),
    ));
    await tester.pump();
    await tester.pump();

    // (a) Collapsed: browse panes are visible.
    expect(find.byType(ArtistColumn), findsOneWidget);

    // (b) Tap "Expand queue" — the browse area should be replaced by the queue.
    await tester.tap(find.byTooltip('Expand queue'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(ArtistColumn), findsNothing);
    expect(find.text('Track A'), findsOneWidget);
  });
}
