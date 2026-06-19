import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/state/layout_settings.dart';
import 'package:olivier/state/providers.dart';

void main() {
  group('parsing', () {
    test('parseFlexPair parses a good pair', () {
      expect(parseFlexPair('1,3', defaultArtistFlex), (1.0, 3.0));
      expect(parseFlexPair('2.5, 1.5', defaultArtistFlex), (2.5, 1.5));
    });
    test('parseFlexPair falls back on bad input', () {
      expect(parseFlexPair(null, defaultArtistFlex), defaultArtistFlex);
      expect(parseFlexPair('oops', defaultArtistFlex), defaultArtistFlex);
      expect(parseFlexPair('1', defaultArtistFlex), defaultArtistFlex);
      expect(parseFlexPair('0,1', defaultArtistFlex), defaultArtistFlex);
      expect(parseFlexPair('-1,2', defaultArtistFlex), defaultArtistFlex);
    });
    test('formatFlexPair round-trips', () {
      expect(parseFlexPair(formatFlexPair((1.0, 2.0)), defaultArtistFlex),
          (1.0, 2.0));
    });
    test('parseQueueHeight parses or defaults', () {
      expect(parseQueueHeight('320'), 320.0);
      expect(parseQueueHeight(null), defaultQueueHeight);
      expect(parseQueueHeight('nope'), defaultQueueHeight);
    });
  });

  test('layoutSettingsProvider loads + parses from the seam', () async {
    final container = ProviderContainer(overrides: [
      getSettingFnProvider.overrideWithValue((key) async => switch (key) {
            'layout.artists' => '1,3',
            'layout.right_pane' => '2,1',
            'layout.queue_height' => '300',
            _ => null,
          }),
    ]);
    addTearDown(container.dispose);

    final s = await container.read(layoutSettingsProvider.future);
    expect(s.artistFlex, (1.0, 3.0));
    expect(s.rightPaneFlex, (2.0, 1.0));
    expect(s.queueHeight, 300.0);
  });

  test('layoutSettingsProvider uses defaults when unset', () async {
    final container = ProviderContainer(overrides: [
      getSettingFnProvider.overrideWithValue((_) async => null),
    ]);
    addTearDown(container.dispose);

    final s = await container.read(layoutSettingsProvider.future);
    expect(s.artistFlex, defaultArtistFlex);
    expect(s.rightPaneFlex, defaultRightPaneFlex);
    expect(s.queueHeight, defaultQueueHeight);
  });
}
