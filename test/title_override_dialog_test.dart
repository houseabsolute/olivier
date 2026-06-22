import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/widgets/title_override_dialog.dart';

void main() {
  group('overrideTitleValue', () {
    test('unchanged from enriched -> null (automatic)', () {
      expect(overrideTitleValue('Kyoku', 'Kyoku'), isNull);
      expect(overrideTitleValue('', null), isNull); // both empty
    });
    test('cleared a non-empty enriched -> "" (suppress)', () {
      expect(overrideTitleValue('', 'Kyoku'), '');
    });
    test('edited -> the text (override)', () {
      expect(overrideTitleValue('NewReading', 'Kyoku'), 'NewReading');
    });
  });

  testWidgets('save maps edited reading + cleared translation to onSubmit', (
    tester,
  ) async {
    String? gotTranslit;
    String? gotTranslate;
    var calls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TitleOverrideDialog(
            label: 'Track',
            current: const TitleOverride(
              translit: 'Kyoku',
              translate: 'Song',
              translitOverride: null,
              translateOverride: null,
            ),
            onSubmit: (t, tr) async {
              calls++;
              gotTranslit = t;
              gotTranslate = tr;
            },
          ),
        ),
      ),
    );

    // Reading is the first TextField, Translation the second.
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));

    // (a) Edit the Reading to a new value -> override.
    await tester.enterText(fields.at(0), 'NewReading');
    // (b) Clear the Translation (was the enriched 'Song') -> suppress.
    await tester.enterText(fields.at(1), '');

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(gotTranslit, 'NewReading'); // edited -> override
    expect(gotTranslate, ''); // cleared a non-empty enriched -> suppress
  });
}
