import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/audio_handler.dart';

void main() {
  group('clampSeek', () {
    test('clamps a below-zero target to zero', () {
      expect(
        clampSeek(const Duration(seconds: 5), const Duration(seconds: -10),
            const Duration(minutes: 3)),
        Duration.zero,
      );
    });

    test('clamps a past-duration target to the duration', () {
      expect(
        clampSeek(const Duration(minutes: 2, seconds: 55),
            const Duration(seconds: 10), const Duration(minutes: 3)),
        const Duration(minutes: 3),
      );
    });

    test('applies no upper clamp when duration is null', () {
      expect(
        clampSeek(
            const Duration(seconds: 5), const Duration(seconds: 10), null),
        const Duration(seconds: 15),
      );
    });

    test('returns the in-range target unchanged', () {
      expect(
        clampSeek(const Duration(seconds: 30), const Duration(seconds: 10),
            const Duration(minutes: 3)),
        const Duration(seconds: 40),
      );
    });
  });
}
