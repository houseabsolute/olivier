import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/widgets/transport_controls.dart';

void main() {
  group('resolveTransport', () {
    test('empty queue disables every button', () {
      final b = resolveTransport(const TransportState(
        hasCurrent: false,
        hasNext: false,
        playing: false,
        isLoading: false,
      ));
      expect(b.prevEnabled, isFalse);
      expect(b.playEnabled, isFalse);
      expect(b.nextEnabled, isFalse);
      expect(b.showSpinner, isFalse);
      expect(b.showPauseIcon, isFalse);
    });

    test('last track: prev + play enabled, next disabled', () {
      final b = resolveTransport(const TransportState(
        hasCurrent: true,
        hasNext: false,
        playing: false,
        isLoading: false,
      ));
      expect(b.prevEnabled, isTrue);
      expect(b.playEnabled, isTrue);
      expect(b.nextEnabled, isFalse);
    });

    test('track with a next: all three enabled', () {
      final b = resolveTransport(const TransportState(
        hasCurrent: true,
        hasNext: true,
        playing: false,
        isLoading: false,
      ));
      expect(b.prevEnabled, isTrue);
      expect(b.playEnabled, isTrue);
      expect(b.nextEnabled, isTrue);
    });

    test('playing shows the pause icon', () {
      final b = resolveTransport(const TransportState(
        hasCurrent: true,
        hasNext: true,
        playing: true,
        isLoading: false,
      ));
      expect(b.showPauseIcon, isTrue);
    });

    test('loading shows the spinner', () {
      final b = resolveTransport(const TransportState(
        hasCurrent: true,
        hasNext: true,
        playing: false,
        isLoading: true,
      ));
      expect(b.showSpinner, isTrue);
    });
  });
}
