import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/widgets/info_dialog.dart';

void main() {
  test('trackInfoFields includes bilingual fields and omits empties', () {
    final t = Track(
      id: 7,
      disc: 1,
      position: 3,
      title: '歌舞伎町の女王',
      artist: 'Sheena Ringo',
      albumArtist: '椎名林檎',
      albumArtistReading: 'Shiina Ringo',
      addedAt: 0,
      lengthMs: BigInt.from(258000),
      titleTranslit: 'Kabukicho no Joo',
      // titleTranslate omitted (null) → must not appear
      // lastPlayed omitted (null) → must not appear
    );
    final fields = trackInfoFields(t);
    final labels = fields.map((f) => f.$1).toList();
    expect(labels, contains('Title'));
    expect(labels, contains('Reading'));
    expect(labels, isNot(contains('Translation'))); // null omitted
    expect(labels, isNot(contains('Last played'))); // null omitted
    expect(labels, isNot(contains('Added at'))); // 0 omitted
    expect(fields.firstWhere((f) => f.$1 == 'Length').$2, '4:18');
    expect(labels, contains('Album artist'));
    expect(labels, isNot(contains('Artist'))); // tag artist dropped
    expect(labels, contains('Album artist reading'));
    expect(fields.firstWhere((f) => f.$1 == 'Album artist').$2, '椎名林檎');
    expect(fields.firstWhere((f) => f.$1 == 'Album artist reading').$2,
        'Shiina Ringo');
  });

  test('trackInfoFields includes Last played and Added at when non-zero', () {
    final t = Track(
      id: 42,
      disc: 1,
      position: 1,
      title: 'Test Song',
      addedAt: 1718800000,
      lastPlayed: 1718900000,
    );
    final fields = trackInfoFields(t);
    final labels = fields.map((f) => f.$1).toList();
    expect(labels, contains('Added at'));
    expect(labels, contains('Last played'));
    // Track id must still appear after the timestamp rows
    expect(labels, contains('Track id'));
    // Order: Last played before Added at before Track id
    final idxLastPlayed = labels.indexOf('Last played');
    final idxAddedAt = labels.indexOf('Added at');
    final idxTrackId = labels.indexOf('Track id');
    expect(idxLastPlayed, lessThan(idxAddedAt));
    expect(idxAddedAt, lessThan(idxTrackId));
  });

  test('albumInfoFields includes Date added when non-zero, omits when 0', () {
    final withDate = Album(
      releaseMbid: 'r1',
      title: 'Album',
      albumArtist: 'Artist',
      addedAt: 1718800000,
    );
    final withDateLabels = albumInfoFields(withDate).map((f) => f.$1).toList();
    expect(withDateLabels, contains('Date added'));

    final withoutDate = Album(
      releaseMbid: 'r1',
      title: 'Album',
      albumArtist: 'Artist',
      addedAt: 0,
    );
    final withoutDateLabels =
        albumInfoFields(withoutDate).map((f) => f.$1).toList();
    expect(withoutDateLabels, isNot(contains('Date added'))); // 0 omitted
  });

  test('queueTrackInfoFields includes present fields and omits null/empty', () {
    final t = QueueTrack(
      path: '/m/a.flac',
      trackId: 7,
      title: 'T',
      artist: 'A',
      albumArtist: '椎名林檎',
      albumArtistReading: 'Shiina Ringo',
      album: 'Al',
      lengthMs: BigInt.from(258000),
      titleTranslit: 'Reading',
      titleTranslate: null,
      addedAt: 1718800000,
      lastPlayed: null,
    );
    final fields = queueTrackInfoFields(t);
    final labels = fields.map((f) => f.$1).toList();
    expect(labels, contains('Album artist'));
    expect(labels, isNot(contains('Artist'))); // tag artist dropped
    expect(labels, contains('Album artist reading'));
    expect(fields.firstWhere((f) => f.$1 == 'Album artist').$2, '椎名林檎');
    expect(fields.firstWhere((f) => f.$1 == 'Album artist reading').$2,
        'Shiina Ringo');
    expect(labels, contains('Album'));
    expect(labels, contains('Path'));
    expect(labels, contains('Date added'));
    expect(labels, isNot(contains('Translation'))); // null omitted
    expect(labels, isNot(contains('Last played'))); // null omitted
  });

  testWidgets('showInfoDialog renders values as SelectableText',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showInfoDialog(context,
                  title: 'Track', fields: const [('Title', '歌舞伎町の女王', null)]),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsWidgets);
    expect(find.text('歌舞伎町の女王'), findsOneWidget);
  });

  group('mbUrl', () {
    test('builds a musicbrainz URL for a real UUID', () {
      const uuid = '11111111-2222-3333-4444-555555555555';
      expect(mbUrl('release', uuid), 'https://musicbrainz.org/release/$uuid');
      expect(mbUrl('artist', uuid), 'https://musicbrainz.org/artist/$uuid');
      expect(
          mbUrl('recording', uuid), 'https://musicbrainz.org/recording/$uuid');
    });
    test('returns null for a synth key or null/empty', () {
      expect(mbUrl('artist', 'synth:aa:foo'), isNull);
      expect(mbUrl('release', 'synth:rel:x|y'), isNull);
      expect(mbUrl('release', null), isNull);
      expect(mbUrl('release', ''), isNull);
      expect(mbUrl('release', 'not-a-uuid'), isNull);
    });
  });

  testWidgets('showInfoDialog renders an optional header above the fields',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showInfoDialog(
                context,
                title: 'Album',
                fields: const [('Title', 'X', null)],
                header: const Text('HEADER', key: Key('hdr')),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hdr')), findsOneWidget);
  });

  test(
      'albumInfoFields links a real Release MBID and adds the album-artist MBID',
      () {
    const rel = '11111111-2222-3333-4444-555555555555';
    const art = 'aaaaaaaa-2222-3333-4444-555555555555';
    final a = Album(
      releaseMbid: rel,
      title: 'Album',
      albumArtist: 'A',
      albumArtistMbid: art,
      addedAt: 0,
    );
    final fields = albumInfoFields(a);
    final release = fields.firstWhere((f) => f.$1 == 'Release MBID');
    expect(release.$2, rel);
    expect(release.$3, 'https://musicbrainz.org/release/$rel');
    final artist = fields.firstWhere((f) => f.$1 == 'Album artist MBID');
    expect(artist.$3, 'https://musicbrainz.org/artist/$art');
  });

  test('synth release MBID is shown but not linked', () {
    final a = Album(
      releaseMbid: 'synth:rel:a|b',
      title: 'Album',
      albumArtist: 'A',
      addedAt: 0,
    );
    final release =
        albumInfoFields(a).firstWhere((f) => f.$1 == 'Release MBID');
    expect(release.$2, 'synth:rel:a|b');
    expect(release.$3, isNull);
  });

  testWidgets('a linked MBID launches its musicbrainz URL when tapped',
      (tester) async {
    final launched = <String>[];
    final orig = launchMbUrl;
    launchMbUrl = (url) async => launched.add(url);
    addTearDown(() => launchMbUrl = orig);

    const uuid = '11111111-2222-3333-4444-555555555555';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showInfoDialog(context, title: 'Album', fields: [
              ('Release MBID', uuid, mbUrl('release', uuid)),
              ('Note', 'plain', null),
            ]),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final link = tester.widget<SelectableText>(find
        .byWidgetPredicate((w) => w is SelectableText && w.textSpan != null));
    final recognizer = link.textSpan!.recognizer! as TapGestureRecognizer;
    recognizer.onTap!();
    await tester.pump();

    expect(launched, ['https://musicbrainz.org/release/$uuid']);
  });
}
