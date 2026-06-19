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

  testWidgets('showInfoDialog renders values as SelectableText',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showInfoDialog(context,
                  title: 'Track', fields: const [('Title', '歌舞伎町の女王')]),
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
}
