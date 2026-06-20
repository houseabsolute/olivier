import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/artist_reading_dialog.dart';

const _reading = ArtistReading(
  name: '椎名林檎',
  nameOriginal: '椎名林檎',
  mbTransliteration: 'Sheena Ringo',
  transliterationOverride: null,
  mbSortName: 'Sheena, Ringo',
  sortNameOverride: null,
);

void main() {
  group('overrideValue', () {
    test('empty or whitespace → null', () {
      expect(overrideValue('', 'Sheena'), isNull);
      expect(overrideValue('   ', 'Sheena'), isNull);
    });
    test('equals MB value (trimmed) → null', () {
      expect(overrideValue('Sheena', 'Sheena'), isNull);
      expect(overrideValue('  Sheena  ', 'Sheena'), isNull);
    });
    test('differs from MB → trimmed value', () {
      expect(overrideValue('Shiina', 'Sheena'), 'Shiina');
      expect(overrideValue('  Shiina  ', 'Sheena'), 'Shiina');
    });
    test('MB null + non-empty → value', () {
      expect(overrideValue('Shiina', null), 'Shiina');
    });
  });

  testWidgets('dialog prefills fields and Save submits computed overrides',
      (tester) async {
    String? gotReading = 'unset';
    String? gotSort = 'unset';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ArtistReadingDialog(
          reading: _reading,
          onSubmit: (r, s) async {
            gotReading = r;
            gotSort = s;
          },
        ),
      ),
    ));

    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(0)).controller!.text,
        'Sheena Ringo');
    expect(tester.widget<TextField>(fields.at(1)).controller!.text,
        'Sheena, Ringo');

    // Prefer "Shiina" for the reading; leave the sort as the MB value.
    await tester.enterText(fields.at(0), 'Shiina Ringo');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(gotReading, 'Shiina Ringo'); // differs from MB → persisted
    expect(gotSort, isNull); // equals MB → no override
  });

  testWidgets('showArtistReadingDialog wires the FFI seam', (tester) async {
    final calls = <(String, String?, String?)>[];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbPathProvider.overrideWithValue(':memory:'),
        artistReadingFnProvider.overrideWithValue((mbid) async => _reading),
        setArtistReadingOverrideFnProvider
            .overrideWithValue((mbid, r, s) async => calls.add((mbid, r, s))),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () =>
                    showArtistReadingDialog(context, ref, 'm-ringo'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Shiina Ringo');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(calls, [('m-ringo', 'Shiina Ringo', null)]);
  });
}
