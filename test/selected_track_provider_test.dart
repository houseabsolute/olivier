import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/state/providers.dart';

void main() {
  test('selectedTrackProvider holds and clears a track id', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(selectedTrackProvider), isNull);

    container.read(selectedTrackProvider.notifier).select(42);
    expect(container.read(selectedTrackProvider), 42);

    container.read(selectedTrackProvider.notifier).clear();
    expect(container.read(selectedTrackProvider), isNull);
  });

  test('selecting an album clears the track selection', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(selectedTrackProvider.notifier).select(7);
    expect(container.read(selectedTrackProvider), 7);

    container.read(selectedAlbumProvider.notifier).select('rel-x');
    expect(container.read(selectedTrackProvider), isNull);
  });
}
