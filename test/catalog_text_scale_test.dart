import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/album_column.dart';
import 'package:olivier/catalog/artist_column.dart';
import 'package:olivier/catalog/track_column.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/bilingual_text.dart';

// Regression tests for bilingual list rows overflowing their fixed extents when
// the OS accessibility text size is enlarged. Each catalog entry below is
// non-Latin, so a row renders TWO lines (original + reading/translation). Two
// body lines are ~36 logical px at 1.0x, so a hard-coded 48px row starts
// clipping them past ~1.33x text scaling; these tests use 1.5x, comfortably in
// the regime where the un-scaled row overflowed (a RenderFlex overflow surfaces
// as a captured exception).

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

/// MaterialApp wrapper that forces [scale] text scaling inside a realistically
/// sized column box.
Widget _scaled(Widget child, double scale) {
  return MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: SizedBox(width: 320, height: 600, child: child),
        ),
      ),
    ),
  );
}

void main() {
  const listScale = 1.5;

  testWidgets('ArtistColumn: two-line rows do not overflow at 1.5x text scale',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        // languageLeadsProvider hydrates from a setting on build; stub the
        // getter so it doesn't hit the real FFI/db.
        getSettingFnProvider.overrideWithValue((key) async => null),
        artistsProvider.overrideWith((ref) => [_artist]),
      ],
      child: _scaled(const ArtistColumn(), listScale),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // Both lines rendered (reading + original script).
    expect(find.text('Ringo Sheena'), findsOneWidget);
    expect(find.text('椎名林檎'), findsOneWidget);
  });

  testWidgets('AlbumColumn: two-line rows do not overflow at 1.5x text scale',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        albumsProvider.overrideWith((ref) => [_album]),
      ],
      child: _scaled(const AlbumColumn(), listScale),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('無罪モラトリアム'), findsOneWidget);
  });

  testWidgets('TrackColumn: two-line rows do not overflow at 1.5x text scale',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        tracksProvider.overrideWith((ref) => [_track]),
      ],
      child: _scaled(const TrackColumn(), listScale),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('歌舞伎町の女王'), findsOneWidget);
  });

  // NowPlayingBar can't be widget-tested directly (it needs a live audio
  // handler), so this checks the equivalent layout: its title area is a Column
  // of a two-line BilingualText title plus a one-line artist, inside a bar whose
  // height comes from bilingualRowExtent(80). At 1.8x a hard-coded 80px bar
  // would clip those three lines; the scaled height must not.
  testWidgets('Now-playing title area fits the scaled bar height at 1.8x',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.8)),
          child: Scaffold(
            body: Builder(
              builder: (context) => Material(
                child: SizedBox(
                  height: bilingualRowExtent(context, 80),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              BilingualText(
                                original: '無罪モラトリアム',
                                translit: 'Muzai Moratorium',
                                translate: null,
                                leads: LanguageLeads.a,
                              ),
                              Text('椎名林檎'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('Muzai Moratorium'), findsOneWidget);
  });
}
