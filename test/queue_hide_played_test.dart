import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';

import 'support/fake_queue_player.dart';

final _tracks = [
  for (var i = 0; i < 5; i++)
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

Widget _app(QueueController qc) {
  return ProviderScope(
    overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      queueControllerProvider.overrideWithValue(qc),
      queueProvider.overrideWith(
        () => _StubQueueNotifier(
          QueueView(tracks: _tracks, currentIndex: 2, shuffled: false),
        ),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: QueuePanel())),
  );
}

void main() {
  group('queueVisibleStart', () {
    test('showPlayed true → 0 regardless of currentIndex', () {
      expect(
        queueVisibleStart(showPlayed: true, currentIndex: 5, trackCount: 10),
        0,
      );
    });
    test('currentIndex null → 0', () {
      expect(
        queueVisibleStart(
            showPlayed: false, currentIndex: null, trackCount: 10),
        0,
      );
    });
    test('hiding, currentIndex 0 → 0', () {
      expect(
        queueVisibleStart(showPlayed: false, currentIndex: 0, trackCount: 10),
        0,
      );
    });
    test('hiding, currentIndex 3 → 3', () {
      expect(
        queueVisibleStart(showPlayed: false, currentIndex: 3, trackCount: 10),
        3,
      );
    });
    test('hiding, last track → currentIndex', () {
      expect(
        queueVisibleStart(showPlayed: false, currentIndex: 9, trackCount: 10),
        9,
      );
    });
    test('stale currentIndex beyond count → clamped to count', () {
      expect(
        queueVisibleStart(showPlayed: false, currentIndex: 12, trackCount: 10),
        10,
      );
    });
    test('negative currentIndex → 0', () {
      expect(
        queueVisibleStart(showPlayed: false, currentIndex: -1, trackCount: 10),
        0,
      );
    });
  });

  group('hide played tracks', () {
    testWidgets(
        'hides tracks before the current one by default; toggle reveals',
        (tester) async {
      final qc = await _seededController();
      await tester.pumpWidget(_app(qc));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Expand queue'));
      await tester.pumpAndSettle();

      // Default: played tracks (canonical 0,1) hidden; current (2) + rest shown.
      expect(find.text('T0'), findsNothing);
      expect(find.text('T1'), findsNothing);
      expect(find.text('T2'), findsOneWidget);
      expect(find.text('T3'), findsOneWidget);
      expect(find.text('T4'), findsOneWidget);
      // Current track keeps its REAL queue number (3), not renumbered to 1.
      expect(find.text('3'), findsOneWidget);
      expect(find.text('1'), findsNothing);

      // Toggle on → every track shown, and T0 now numbered 1.
      await tester.tap(find.byTooltip('Show played tracks'));
      await tester.pumpAndSettle();
      expect(find.text('T0'), findsOneWidget);
      expect(find.text('T1'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });
  });
}
