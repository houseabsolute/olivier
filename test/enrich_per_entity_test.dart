import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/enrich/progress.dart';
import 'package:olivier/state/enrich_controller.dart';
import 'package:olivier/state/providers.dart';

void main() {
  test('enrichArtist runs single-flight and finishes not-running', () async {
    final container = ProviderContainer(overrides: [
      dbPathProvider.overrideWithValue('/x.db'),
      enrichArtistFnProvider.overrideWithValue((mbid) async* {
        yield EnrichProgress(
            entitiesDone: BigInt.one,
            entitiesTotal: BigInt.one,
            current: 'A',
            done: true);
      }),
    ]);
    addTearDown(container.dispose);

    await container.read(enrichControllerProvider.notifier).enrichArtist('A');
    expect(container.read(enrichControllerProvider).running, isFalse);
  });
}
