import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/volume.dart';

void main() {
  group('parseVolume', () {
    test('parses a good value', () {
      expect(parseVolume('0.4'), 0.4);
    });
    test('clamps out-of-range values', () {
      expect(parseVolume('1.5'), 1.0);
      expect(parseVolume('-0.2'), 0.0);
    });
    test('falls back to defaultVolume on null/garbage', () {
      expect(parseVolume(null), defaultVolume);
      expect(parseVolume('oops'), defaultVolume);
    });
  });

  test('volumeProvider loads the saved volume and applies it on build',
      () async {
    final applied = <double>[];
    final saved = <(String, String)>[];
    final container = ProviderContainer(overrides: [
      getSettingFnProvider
          .overrideWithValue((key) async => key == volumeKey ? '0.4' : null),
      setSettingFnProvider
          .overrideWithValue((key, value) async => saved.add((key, value))),
      setVolumeFnProvider.overrideWithValue((v) async => applied.add(v)),
    ]);
    addTearDown(container.dispose);

    // build() loads 0.4 and applies it to the player via the seam.
    expect(await container.read(volumeProvider.future), 0.4);
    expect(applied, [0.4]);

    // setVolume(persist: true) applies and saves.
    await container.read(volumeProvider.notifier).setVolume(0.7, persist: true);
    expect(applied, [0.4, 0.7]);
    expect(saved, [(volumeKey, '0.7')]);

    // setVolume without persist applies but does not save.
    applied.clear();
    saved.clear();
    await container.read(volumeProvider.notifier).setVolume(0.6);
    expect(applied, [0.6]);
    expect(saved, isEmpty);
  });
}
