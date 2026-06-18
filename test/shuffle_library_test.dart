import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';

class _FakeController implements ShuffleAllTarget {
  List<String>? replaced;
  @override
  Future<void> replaceLibraryShuffled(List<String> paths) async {
    replaced = paths;
  }
}

class _FakeQueueNotifier extends QueueNotifier {
  _FakeQueueNotifier(this._count);
  final int _count;
  @override
  Future<QueueView> build() async => QueueView(
        tracks: [
          for (var i = 0; i < _count; i++)
            QueueTrack(path: '/q/$i', title: 'T$i', album: 'A'),
        ],
        currentIndex: _count == 0 ? null : 0,
        shuffled: false,
      );
}

Widget _host(_FakeController fake, {required int queueCount}) {
  return ProviderScope(
    overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      libraryPathsFnProvider.overrideWithValue(
        () async => ['/m/1', '/m/2', '/m/3'],
      ),
      shuffleAllTargetProvider.overrideWithValue(fake),
      queueProvider.overrideWith(() => _FakeQueueNotifier(queueCount)),
    ],
    child: const MaterialApp(home: Scaffold(body: QueuePanel())),
  );
}

void main() {
  testWidgets('empty queue: Shuffle all replaces immediately, no dialog',
      (tester) async {
    final fake = _FakeController();
    await tester.pumpWidget(_host(fake, queueCount: 0));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Shuffle entire library'));
    await tester.pumpAndSettle();

    expect(find.text('Shuffle entire library?'), findsNothing);
    expect(fake.replaced, ['/m/1', '/m/2', '/m/3']);
  });

  testWidgets('non-empty queue: confirm dialog shows count, confirm replaces',
      (tester) async {
    final fake = _FakeController();
    await tester.pumpWidget(_host(fake, queueCount: 5));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Shuffle entire library'));
    await tester.pumpAndSettle();

    // Dialog states the count of library tracks that will replace the queue.
    expect(find.textContaining('3 tracks'), findsOneWidget);
    expect(fake.replaced, isNull);

    await tester.tap(find.text('Shuffle'));
    await tester.pumpAndSettle();
    expect(fake.replaced, ['/m/1', '/m/2', '/m/3']);
  });

  // Spec §6: tapping Cancel on the confirm dialog must NOT replace the queue.
  testWidgets('non-empty queue: cancel dialog leaves queue unchanged',
      (tester) async {
    final fake = _FakeController();
    await tester.pumpWidget(_host(fake, queueCount: 5));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Shuffle entire library'));
    await tester.pumpAndSettle();

    // Dialog is visible.
    expect(find.text('Shuffle entire library?'), findsOneWidget);
    expect(fake.replaced, isNull);

    // Tap Cancel.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Dialog dismissed and replace was NOT called.
    expect(find.text('Shuffle entire library?'), findsNothing);
    expect(fake.replaced, isNull);
  });
}
