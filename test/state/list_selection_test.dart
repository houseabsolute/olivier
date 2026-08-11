import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/state/list_selection.dart';

const _rows = ['a', 'b', 'c', 'd', 'e'];

ListSelection _tap(
        ListSelection from, String key, SelectionModifier modifier) =>
    applyRowTap(
      current: from,
      rowKeys: _rows,
      key: key,
      modifier: modifier,
    );

void main() {
  group('applyRowTap', () {
    test('a plain click replaces the selection and re-anchors', () {
      final s = _tap(
        const ListSelection(keys: {'a', 'b'}, anchor: 'a'),
        'd',
        SelectionModifier.none,
      );
      expect(s.keys, {'d'});
      expect(s.anchor, 'd');
    });

    test('toggle adds to the selection', () {
      final s = _tap(const ListSelection(keys: {'a'}, anchor: 'a'), 'c',
          SelectionModifier.toggle);
      expect(s.keys, {'a', 'c'});
      expect(s.anchor, 'c');
    });

    test('toggle removes a row that was already selected', () {
      final s = _tap(const ListSelection(keys: {'a', 'c'}, anchor: 'a'), 'a',
          SelectionModifier.toggle);
      expect(s.keys, {'c'});
    });

    test('toggling the last row off leaves nothing selected', () {
      final s = _tap(const ListSelection(keys: {'a'}, anchor: 'a'), 'a',
          SelectionModifier.toggle);
      expect(s.isEmpty, isTrue);
    });

    test('range takes the run from the anchor, inclusive', () {
      final s = _tap(const ListSelection(keys: {'b'}, anchor: 'b'), 'd',
          SelectionModifier.range);
      expect(s.keys, {'b', 'c', 'd'});
    });

    test('range works backwards too', () {
      final s = _tap(const ListSelection(keys: {'d'}, anchor: 'd'), 'b',
          SelectionModifier.range);
      expect(s.keys, {'b', 'c', 'd'});
    });

    test('the anchor survives a range, so the run can be resized', () {
      final first = _tap(const ListSelection(keys: {'b'}, anchor: 'b'), 'e',
          SelectionModifier.range);
      final resized = _tap(first, 'c', SelectionModifier.range);
      expect(resized.keys, {'b', 'c'}, reason: 'still measured from b');
      expect(resized.anchor, 'b');
    });

    test('range with no anchor degrades to a plain click', () {
      final s = _tap(const ListSelection(), 'c', SelectionModifier.range);
      expect(s.keys, {'c'});
      expect(s.anchor, 'c');
    });

    test('range from an anchor that has left the list degrades too', () {
      final s = _tap(const ListSelection(keys: {'z'}, anchor: 'z'), 'c',
          SelectionModifier.range);
      expect(s.keys, {'c'});
    });
  });

  group('ListSelection', () {
    test('ordered() follows the list, not the click order', () {
      const s = ListSelection(keys: {'d', 'a', 'c'});
      expect(s.ordered(_rows), ['a', 'c', 'd']);
    });

    test('ordered() drops keys no longer in the list', () {
      const s = ListSelection(keys: {'a', 'gone'});
      expect(s.ordered(_rows), ['a']);
    });

    test('isMulti only once more than one row is in', () {
      expect(const ListSelection(keys: {'a'}).isMulti, isFalse);
      expect(const ListSelection(keys: {'a', 'b'}).isMulti, isTrue);
    });
  });

  group('selectionLabel', () {
    test('null for a single row, so the menu keeps its plain wording', () {
      expect(selectionLabel(const ListSelection(keys: {'a'}), 'album'), isNull);
    });
    test('counts and pluralises for several', () {
      expect(selectionLabel(const ListSelection(keys: {'a', 'b'}), 'album'),
          '2 albums');
      expect(
          selectionLabel(const ListSelection(keys: {'a', 'b', 'c'}), 'track'),
          '3 tracks');
    });
  });
}
