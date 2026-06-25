import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/playlists/playlists_page.dart';

void main() {
  test('reordered moves an item down (ReorderableListView convention)', () {
    expect(reordered([0, 1, 2, 3], 0, 2), [1, 0, 2, 3]);
  });
  test('reordered moves an item up', () {
    expect(reordered([0, 1, 2, 3], 3, 1), [0, 3, 1, 2]);
  });
}
