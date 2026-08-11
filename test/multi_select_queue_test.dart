import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/list_selection.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';
import 'package:olivier/state/queue_view.dart';

import 'support/fake_queue_player.dart';

final _tracks = [
  for (var i = 0; i < 4; i++)
    QueueTrack(path: '/$i.flac', title: 'T$i', album: 'X', addedAt: 0),
];

class _StubQueueNotifier extends QueueNotifier {
  _StubQueueNotifier(this._value);
  final QueueView _value;
  @override
  Future<QueueView> build() async => _value;
}

Future<QueueController> _seededController() async {
  final qc = QueueController.withPlayer(
    FakeQueuePlayer(),
    dbPath: ':memory:',
    saveQueue: (_) async {},
  );
  await qc.append([for (final t in _tracks) t.path]);
  return qc;
}

ProviderContainer _container(QueueController qc) => ProviderContainer(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        queueControllerProvider.overrideWithValue(qc),
        queueProvider.overrideWith(
          () => _StubQueueNotifier(
            // Showing played tracks so every row is on screen to click.
            QueueView(tracks: _tracks, currentIndex: 0, shuffled: false),
          ),
        ),
        showPlayedProvider.overrideWith(_AlwaysShowPlayed.new),
      ],
    );

class _AlwaysShowPlayed extends ShowPlayed {
  @override
  bool build() => true;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: Scaffold(body: QueuePanel())),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Expand queue'));
  await tester.pumpAndSettle();
}

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

void main() {
  group('QueueController.removeAtAll', () {
    test('removes every index, addressing the list as it was', () async {
      final qc = await _seededController();
      await qc.removeAtAll([0, 2]);
      expect(qc.orderedPaths, ['/1.flac', '/3.flac']);
    });

    test('order of the indices does not matter, and duplicates are ignored',
        () async {
      final qc = await _seededController();
      await qc.removeAtAll([3, 1, 1]);
      expect(qc.orderedPaths, ['/0.flac', '/2.flac']);
    });

    test('out-of-range indices are skipped, not fatal', () async {
      final qc = await _seededController();
      await qc.removeAtAll([-1, 2, 99]);
      expect(qc.orderedPaths, ['/0.flac', '/1.flac', '/3.flac']);
    });

    test('an empty set changes nothing and does not revise', () async {
      final qc = await _seededController();
      final revision = qc.revision.value;
      await qc.removeAtAll([]);
      expect(qc.orderedPaths.length, 4);
      expect(qc.revision.value, revision);
    });

    test('the play order is kept in step', () async {
      final qc = await _seededController();
      await qc.removeAtAll([0, 1]);
      expect(qc.playOrder, ['/2.flac', '/3.flac']);
    });
  });

  testWidgets('selected queue rows are removed together', (tester) async {
    final qc = await _seededController();
    final container = _container(qc);
    addTearDown(container.dispose);
    await _pump(tester, container);

    await tester.tap(find.text('T1'));
    await tester.pumpAndSettle();
    await _tapWith(tester, LogicalKeyboardKey.controlLeft, find.text('T3'));
    expect(container.read(queueSelectionProvider).keys, {'1', '3'});

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('T3')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Remove 2 tracks from queue'), findsOneWidget);
    await tester.tap(find.text('Remove 2 tracks from queue'));
    await tester.pumpAndSettle();

    expect(qc.orderedPaths, ['/0.flac', '/2.flac']);
    // The removal renumbered the rows, so the old keys are dropped.
    expect(container.read(queueSelectionProvider).isEmpty, isTrue);
  });

  testWidgets('a single row still removes just itself', (tester) async {
    final qc = await _seededController();
    final container = _container(qc);
    addTearDown(container.dispose);
    await _pump(tester, container);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('T2')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Remove from queue'), findsOneWidget);
    await tester.tap(find.text('Remove from queue'));
    await tester.pumpAndSettle();

    expect(qc.orderedPaths, ['/0.flac', '/1.flac', '/3.flac']);
  });
}
