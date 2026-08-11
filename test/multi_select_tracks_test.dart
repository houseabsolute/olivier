import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/catalog/track_column.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/list_selection.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';

import 'support/fake_queue_player.dart';

final _tracks = [
  for (var i = 1; i <= 4; i++)
    Track(id: i, disc: 1, position: i, title: 'Song $i', addedAt: 0),
];

class _StubAlbum extends SelectedAlbum {
  @override
  String? build() => 'rel-1';
}

/// Track ids the "remove from library" seam was called with, in order.
final removed = <int>[];

ProviderContainer _container(QueueController qc) {
  removed.clear();
  return ProviderContainer(overrides: [
    dbPathProvider.overrideWithValue(':memory:'),
    getSettingFnProvider.overrideWithValue((key) async => null),
    tracksProvider.overrideWith((ref) => _tracks),
    selectedAlbumProvider.overrideWith(_StubAlbum.new),
    queueControllerProvider.overrideWithValue(qc),
    entityPathFnsProvider.overrideWithValue(EntityPathFns(
      artistPaths: (_) async => [],
      albumPaths: (_) async => [],
      trackPath: (id) async => '/m/$id.flac',
    )),
    removeTrackFnProvider.overrideWithValue((id) async => removed.add(id)),
    // Touched by the post-removal reconcile in runCatalogMutation.
    artistsProvider.overrideWith((ref) => <Artist>[]),
    albumsProvider.overrideWith((ref) => <Album>[]),
    tracksForPathsFnProvider.overrideWithValue((paths) async => []),
  ]);
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: Scaffold(body: TrackColumn())),
  ));
  await tester.pumpAndSettle();
}

/// Tap [finder] with a modifier key held, the way a real Ctrl/Shift-click
/// reaches the selection code (which reads HardwareKeyboard, not the event).
Future<void> _tapWith(
  WidgetTester tester,
  LogicalKeyboardKey key,
  Finder finder,
) async {
  await tester.sendKeyDownEvent(key);
  await tester.tap(finder);
  await tester.sendKeyUpEvent(key);
  await tester.pumpAndSettle();
}

Future<void> _openMenu(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    buttons: kSecondaryButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('ctrl-click adds rows without drilling into them',
      (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/x.db', saveQueue: (_) async {});
    final container = _container(qc);
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.tap(find.text('Song 1'));
    await tester.pumpAndSettle();
    await _tapWith(tester, LogicalKeyboardKey.controlLeft, find.text('Song 3'));

    expect(container.read(trackSelectionProvider).keys, {'1', '3'});
    // The plain click drilled in; the modified one left that alone.
    expect(container.read(selectedTrackProvider), 1);

    // Ctrl-clicking a selected row takes it back out.
    await _tapWith(tester, LogicalKeyboardKey.controlLeft, find.text('Song 3'));
    expect(container.read(trackSelectionProvider).keys, {'1'});
  });

  testWidgets('shift-click selects the run between the two rows',
      (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/x.db', saveQueue: (_) async {});
    final container = _container(qc);
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.tap(find.text('Song 2'));
    await tester.pumpAndSettle();
    await _tapWith(tester, LogicalKeyboardKey.shiftLeft, find.text('Song 4'));

    expect(container.read(trackSelectionProvider).keys, {'2', '3', '4'});
  });

  testWidgets('the menu names the selection and enqueues all of it',
      (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/x.db', saveQueue: (_) async {});
    final container = _container(qc);
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.tap(find.text('Song 1'));
    await tester.pumpAndSettle();
    await _tapWith(tester, LogicalKeyboardKey.controlLeft, find.text('Song 3'));

    await _openMenu(tester, find.text('Song 3'));
    // Multi-row menu: bulk entries name the selection, single-row ones go away.
    expect(find.text('Add 2 tracks to queue'), findsOneWidget);
    expect(find.text('Remove 2 tracks from library'), findsOneWidget);
    expect(find.text('Info'), findsNothing);

    await tester.tap(find.text('Add 2 tracks to queue'));
    await tester.pumpAndSettle();

    // Enqueued in list order, not click order.
    expect(qc.orderedPaths, ['/m/1.flac', '/m/3.flac']);
  });

  testWidgets('removing from the library removes every selected track',
      (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/x.db', saveQueue: (_) async {});
    final container = _container(qc);
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.tap(find.text('Song 2'));
    await tester.pumpAndSettle();
    await _tapWith(tester, LogicalKeyboardKey.shiftLeft, find.text('Song 3'));

    await _openMenu(tester, find.text('Song 2'));
    await tester.tap(find.text('Remove 2 tracks from library'));
    await tester.pumpAndSettle();

    expect(removed, [2, 3]);
    expect(container.read(trackSelectionProvider).isEmpty, isTrue);
  });

  testWidgets('right-clicking outside the selection retargets the menu',
      (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/x.db', saveQueue: (_) async {});
    final container = _container(qc);
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.tap(find.text('Song 1'));
    await tester.pumpAndSettle();
    await _tapWith(tester, LogicalKeyboardKey.controlLeft, find.text('Song 2'));

    // Song 4 is not in the selection, so the menu speaks for it alone.
    await _openMenu(tester, find.text('Song 4'));
    expect(find.text('Add to queue'), findsOneWidget);
    expect(find.text('Info'), findsOneWidget);

    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();
    expect(qc.orderedPaths, ['/m/4.flac']);
    expect(container.read(trackSelectionProvider).keys, {'4'});
  });

  testWidgets('switching album drops the selection', (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/x.db', saveQueue: (_) async {});
    final container = _container(qc);
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.tap(find.text('Song 1'));
    await tester.pumpAndSettle();
    await _tapWith(tester, LogicalKeyboardKey.controlLeft, find.text('Song 2'));
    expect(container.read(trackSelectionProvider).length, 2);

    container.read(selectedAlbumProvider.notifier).select('rel-2');
    await tester.pumpAndSettle();

    expect(container.read(trackSelectionProvider).isEmpty, isTrue,
        reason: 'the old ids address rows that are no longer listed');
  });
}
