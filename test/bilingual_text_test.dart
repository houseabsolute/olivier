import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/widgets/bilingual_text.dart';

void main() {
  group('resolveBilingual', () {
    test('layout A name: reading leads, original beneath', () {
      final r = resolveBilingual(
        original: '椎名林檎',
        translit: 'Ringo Sheena',
        translate: null,
        leads: LanguageLeads.a,
      );
      expect(r.primary, 'Ringo Sheena');
      expect(r.secondary, '椎名林檎');
    });

    test('layout A title with both alts: romaji and translation joined', () {
      final r = resolveBilingual(
        original: '無罪モラトリアム',
        translit: 'Muzai Moratorium',
        translate: 'Innocence Moratorium',
        leads: LanguageLeads.a,
      );
      expect(r.primary, 'Muzai Moratorium · Innocence Moratorium');
      expect(r.secondary, '無罪モラトリアム');
    });

    test('layout A title with only translation', () {
      final r = resolveBilingual(
        original: '無罪モラトリアム',
        translit: null,
        translate: 'Innocence Moratorium',
        leads: LanguageLeads.a,
      );
      expect(r.primary, 'Innocence Moratorium');
      expect(r.secondary, '無罪モラトリアム');
    });

    test('layout B: original leads, reading beneath', () {
      final r = resolveBilingual(
        original: '椎名林檎',
        translit: 'Ringo Sheena',
        translate: null,
        leads: LanguageLeads.b,
      );
      expect(r.primary, '椎名林檎');
      expect(r.secondary, 'Ringo Sheena');
    });

    test('Latin-only collapses to a single line (no secondary)', () {
      final r = resolveBilingual(
        original: 'The Beatles',
        translit: null,
        translate: null,
        leads: LanguageLeads.a,
      );
      expect(r.primary, 'The Beatles');
      expect(r.secondary, isNull);
    });

    test('alt equal to original (case-insensitive) collapses', () {
      final r = resolveBilingual(
        original: 'Cornelius',
        translit: 'cornelius',
        translate: null,
        leads: LanguageLeads.a,
      );
      expect(r.primary, 'Cornelius');
      expect(r.secondary, isNull);
    });

    test('Latin original ignores a differing reading (single line)', () {
      // "TOKYO" is already Latin — a "Tokyo" reading is noise, so show one line.
      final r = resolveBilingual(
        original: 'TOKYO',
        translit: 'Tokyo',
        translate: null,
        leads: LanguageLeads.a,
      );
      expect(r.primary, 'TOKYO');
      expect(r.secondary, isNull);
    });

    test('drops an alternate that is the original script again', () {
      // A "translation" that carries the original Japanese must not render the
      // original twice — only the romaji reading remains as the alternate.
      final r = resolveBilingual(
        original: '三毒史',
        translit: 'Sandokushi',
        translate: '三毒史',
        leads: LanguageLeads.a,
      );
      expect(r.primary, 'Sandokushi');
      expect(r.secondary, '三毒史');
    });
  });

  testWidgets('BilingualText renders two lines in layout A', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BilingualText(
            original: '椎名林檎',
            translit: 'Ringo Sheena',
            translate: null,
            leads: LanguageLeads.a,
          ),
        ),
      ),
    );
    expect(find.text('Ringo Sheena'), findsOneWidget);
    expect(find.text('椎名林檎'), findsOneWidget);
  });

  testWidgets('BilingualText renders one line when Latin-only', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BilingualText(
            original: 'The Beatles',
            translit: null,
            translate: null,
            leads: LanguageLeads.a,
          ),
        ),
      ),
    );
    expect(find.text('The Beatles'), findsOneWidget);
  });

  // The prefix/suffix attach to the LEADING (primary) line only, AFTER
  // resolveBilingual picks primary/secondary. They must stay on the top line
  // in both layouts and in the translate-only and Latin-only cases.
  testWidgets('suffix sits on the leading line in layout A', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BilingualText(
            original: '無罪モラトリアム',
            translit: 'Muzai Moratorium',
            translate: null,
            leads: LanguageLeads.a,
            suffix: ' (1999)',
          ),
        ),
      ),
    );
    // Reading leads in A, so the suffix rides the reading line; original is bare.
    expect(find.text('Muzai Moratorium (1999)'), findsOneWidget);
    expect(find.text('無罪モラトリアム'), findsOneWidget);
  });

  testWidgets('suffix sits on the leading line in layout B', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BilingualText(
            original: '無罪モラトリアム',
            translit: 'Muzai Moratorium',
            translate: null,
            leads: LanguageLeads.b,
            suffix: ' (1999)',
          ),
        ),
      ),
    );
    // Original leads in B, so the suffix rides the original line; reading is bare.
    expect(find.text('無罪モラトリアム (1999)'), findsOneWidget);
    expect(find.text('Muzai Moratorium'), findsOneWidget);
  });

  testWidgets(
      'translate-only: suffix stays on the leading translation line in A',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BilingualText(
            original: '無罪モラトリアム',
            translit: null,
            translate: 'Innocence Moratorium',
            leads: LanguageLeads.a,
            suffix: ' (1999)',
          ),
        ),
      ),
    );
    // Translation leads in A; the year must ride it, not the bare original.
    expect(find.text('Innocence Moratorium (1999)'), findsOneWidget);
    expect(find.text('無罪モラトリアム'), findsOneWidget);
  });

  testWidgets('Latin-only single line still carries the suffix',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BilingualText(
            original: 'Sport',
            translit: null,
            translate: null,
            leads: LanguageLeads.a,
            suffix: ' (2014)',
          ),
        ),
      ),
    );
    expect(find.text('Sport (2014)'), findsOneWidget);
  });
}
