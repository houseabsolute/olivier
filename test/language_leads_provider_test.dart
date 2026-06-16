import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/bilingual_text.dart';

void main() {
  test('hydrates from getSetting=B', () async {
    String? stored = 'B';
    final container = ProviderContainer(
      overrides: [
        dbPathProvider.overrideWithValue('/tmp/x.db'),
        getSettingFnProvider.overrideWithValue((key) async => stored),
        setSettingFnProvider.overrideWithValue((key, value) async {
          stored = value;
        }),
      ],
    );
    addTearDown(container.dispose);

    // Default before hydration.
    expect(container.read(languageLeadsProvider), LanguageLeads.a);
    // Let the async hydrate complete.
    await container.read(languageLeadsProvider.notifier).hydrate();
    expect(container.read(languageLeadsProvider), LanguageLeads.b);
  });

  test('toggle persists and flips state', () async {
    String? stored = 'A';
    final container = ProviderContainer(
      overrides: [
        dbPathProvider.overrideWithValue('/tmp/x.db'),
        getSettingFnProvider.overrideWithValue((key) async => stored),
        setSettingFnProvider.overrideWithValue((key, value) async {
          stored = value;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(languageLeadsProvider.notifier).toggle();
    expect(container.read(languageLeadsProvider), LanguageLeads.b);
    expect(stored, 'B');

    await container.read(languageLeadsProvider.notifier).toggle();
    expect(container.read(languageLeadsProvider), LanguageLeads.a);
    expect(stored, 'A');
  });
}
