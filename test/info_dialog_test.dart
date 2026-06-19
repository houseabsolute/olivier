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
    );
    final fields = trackInfoFields(t);
    final labels = fields.map((f) => f.$1).toList();
    expect(labels, contains('Title'));
    expect(labels, contains('Reading'));
    expect(labels, isNot(contains('Translation'))); // null omitted
    expect(fields.firstWhere((f) => f.$1 == 'Length').$2, '4:18');
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
