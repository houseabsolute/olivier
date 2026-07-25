import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_view.dart';
import 'package:olivier/widgets/search_field.dart';

void main() {
  testWidgets('typing updates the query after debounce', (tester) async {
    final container = ProviderContainer(
      overrides: [dbPathProvider.overrideWithValue(':memory:')],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SearchField())),
    ));

    await tester.enterText(find.byType(TextField), 'ringo');
    await tester.pump(const Duration(milliseconds: 200));
    expect(container.read(searchQueryProvider), 'ringo');
  });

  testWidgets('Esc clears the query and the field', (tester) async {
    final container = ProviderContainer(
      overrides: [dbPathProvider.overrideWithValue(':memory:')],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SearchField())),
    ));
    await tester.enterText(find.byType(TextField), 'ringo');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(container.read(searchQueryProvider), '');
    expect(
        (tester.widget(find.byType(TextField)) as TextField).controller!.text,
        '');
  });

  testWidgets('arrow-down + Enter selects the hit and collapses the queue',
      (tester) async {
    final container = ProviderContainer(overrides: [
      dbPathProvider.overrideWithValue(':memory:'),
      searchCatalogFnProvider
          .overrideWithValue((q, limit) async => SearchResults(artists: [
                const Artist(
                    mbid: 'A',
                    name: 'Shiina Ringo',
                    sortName: 'Shiina, Ringo',
                    transliteration: 'Shiina Ringo',
                    nameOriginal: null),
              ], albums: const [], tracks: const [])),
    ]);
    addTearDown(container.dispose);
    container.read(queueExpandedProvider.notifier).toggle();
    // The field only reads the results provider; in the app the dropdown keeps
    // it subscribed, so listen here or it never resolves and Enter finds no hit.
    container.listen(searchResultsProvider, (_, __) {});

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SearchField())),
    ));
    await tester.enterText(find.byType(TextField), 'ringo');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(container.read(selectedArtistProvider), 'A');
    expect(container.read(queueExpandedProvider), isFalse);
  });

  testWidgets('Esc within the debounce window cancels the pending set',
      (tester) async {
    final container = ProviderContainer(
      overrides: [dbPathProvider.overrideWithValue(':memory:')],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SearchField())),
    ));

    await tester.enterText(find.byType(TextField), 'ringo');
    // Esc BEFORE the 150ms debounce fires.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    // Let the (now-cancelled) debounce window fully elapse.
    await tester.pump(const Duration(milliseconds: 200));
    expect(container.read(searchQueryProvider), '',
        reason: 'a cancelled debounce must not re-populate the query');
  });
}
