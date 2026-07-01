import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/queue_panel.dart';

void main() {
  group('queueVisibleStart', () {
    test('showPlayed true → 0 regardless of currentIndex', () {
      expect(
        queueVisibleStart(showPlayed: true, currentIndex: 5, trackCount: 10),
        0,
      );
    });
    test('currentIndex null → 0', () {
      expect(
        queueVisibleStart(showPlayed: false, currentIndex: null, trackCount: 10),
        0,
      );
    });
    test('hiding, currentIndex 0 → 0', () {
      expect(
        queueVisibleStart(showPlayed: false, currentIndex: 0, trackCount: 10),
        0,
      );
    });
    test('hiding, currentIndex 3 → 3', () {
      expect(
        queueVisibleStart(showPlayed: false, currentIndex: 3, trackCount: 10),
        3,
      );
    });
    test('hiding, last track → currentIndex', () {
      expect(
        queueVisibleStart(showPlayed: false, currentIndex: 9, trackCount: 10),
        9,
      );
    });
    test('stale currentIndex beyond count → clamped to count', () {
      expect(
        queueVisibleStart(showPlayed: false, currentIndex: 12, trackCount: 10),
        10,
      );
    });
    test('negative currentIndex → 0', () {
      expect(
        queueVisibleStart(showPlayed: false, currentIndex: -1, trackCount: 10),
        0,
      );
    });
  });
}
