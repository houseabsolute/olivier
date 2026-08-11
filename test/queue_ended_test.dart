import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';
import 'package:olivier/state/queue_view.dart';

import 'support/fake_queue_player.dart';

final _tracks = [
  for (var i = 0; i < 3; i++)
    QueueTrack(path: '/$i.flac', title: 'T$i', album: 'X', addedAt: 0),
];

class _StubQueueNotifier extends QueueNotifier {
  _StubQueueNotifier(this._value);
  final QueueView _value;
  @override
  Future<QueueView> build() async => _value;
}

Widget _app(QueueController qc, QueueView view) {
  return ProviderScope(
    overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      queueControllerProvider.overrideWithValue(qc),
      queueProvider.overrideWith(() => _StubQueueNotifier(view)),
    ],
    child: const MaterialApp(home: Scaffold(body: QueuePanel())),
  );
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

void main() {
  group('QueueController.ended', () {
    test('markEnded flags the queue and bumps the revision', () async {
      final qc = await _seededController();
      final before = qc.revision.value;
      expect(qc.ended, isFalse);

      qc.markEnded();
      expect(qc.ended, isTrue);
      expect(qc.revision.value, before + 1);

      // Completion re-emits on later player events; only the first counts.
      qc.markEnded();
      expect(qc.revision.value, before + 1);
    });

    test('an empty queue never ends (nothing to show as finished)', () {
      final qc = QueueController.withPlayer(
        FakeQueuePlayer(),
        dbPath: ':memory:',
        saveQueue: (_) async {},
      );
      qc.markEnded();
      expect(qc.ended, isFalse);
    });

    test('appending more tracks un-ends the queue', () async {
      final qc = await _seededController();
      qc.markEnded();
      await qc.append(['/3.flac']);
      expect(qc.ended, isFalse);
    });

    test('playing a track again un-ends the queue', () async {
      final qc = await _seededController();
      qc.markEnded();
      await qc.playAt(0);
      expect(qc.ended, isFalse);
    });

    test('clearing un-ends the queue', () async {
      final qc = await _seededController();
      qc.markEnded();
      await qc.clear();
      expect(qc.ended, isFalse);
    });
  });

  group('queueVisibleStart', () {
    test('ended → past the last row, so nothing is listed', () {
      expect(
        queueVisibleStart(
            showPlayed: false, currentIndex: 9, trackCount: 10, ended: true),
        10,
      );
    });
    test('ended but showing played tracks → still starts at 0', () {
      expect(
        queueVisibleStart(
            showPlayed: true, currentIndex: 9, trackCount: 10, ended: true),
        0,
      );
    });
  });

  testWidgets('after the last track finishes the queue lists nothing',
      (tester) async {
    final qc = await _seededController();
    await tester.pumpWidget(_app(
      qc,
      QueueView(
        tracks: _tracks,
        currentIndex: _tracks.length - 1,
        shuffled: false,
        ended: true,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Expand queue'));
    await tester.pumpAndSettle();

    // The finished track is not still sitting there as if it were up.
    expect(find.text('T2'), findsNothing);
    expect(find.text('T0'), findsNothing);
    // Nothing is up next either, and the queue itself is intact.
    expect(find.textContaining('up next'), findsNothing);
    expect(find.textContaining('Queue · 3 tracks'), findsOneWidget);

    // Showing played tracks brings the whole (finished) queue back.
    await tester.tap(find.byTooltip('Show played tracks'));
    await tester.pumpAndSettle();
    expect(find.text('T0'), findsOneWidget);
    expect(find.text('T2'), findsOneWidget);
  });
}
