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

const _tracks = [
  // Disc 1 track 7, a multi-disc entry, and a path that left the catalog.
  QueueTrack(
      path: '/a.flac',
      title: 'One',
      album: 'X',
      addedAt: 0,
      disc: 1,
      position: 7),
  QueueTrack(
      path: '/b.flac',
      title: 'Two',
      album: 'X',
      addedAt: 0,
      disc: 2,
      position: 5),
  QueueTrack(path: '/c.flac', title: 'Three', album: 'X', addedAt: 0),
];

class _StubQueueNotifier extends QueueNotifier {
  _StubQueueNotifier(this._value);
  final QueueView _value;
  @override
  Future<QueueView> build() async => _value;
}

Widget _app(QueueController qc) {
  return ProviderScope(
    overrides: [
      getSettingFnProvider.overrideWithValue((key) async => null),
      queueControllerProvider.overrideWithValue(qc),
      queueProvider.overrideWith(
        () => _StubQueueNotifier(
          const QueueView(tracks: _tracks, currentIndex: 0, shuffled: false),
        ),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: QueuePanel())),
  );
}

void main() {
  group('queueTrackNumber', () {
    test('single-disc release shows the bare position', () {
      expect(queueTrackNumber(_tracks[0]), '7');
    });
    test('later disc is prefixed', () {
      expect(queueTrackNumber(_tracks[1]), '2-5');
    });
    test('entry no longer in the catalog has no number', () {
      expect(queueTrackNumber(_tracks[2]), '');
    });
    test('missing disc is treated as disc 1', () {
      expect(
        queueTrackNumber(const QueueTrack(
            path: '/d.flac', title: 'D', album: 'X', addedAt: 0, position: 3)),
        '3',
      );
    });
  });

  testWidgets('expanded queue rows show the album track number',
      (tester) async {
    final qc = QueueController.withPlayer(
      FakeQueuePlayer(),
      dbPath: ':memory:',
      saveQueue: (_) async {},
    );
    await qc.append([for (final t in _tracks) t.path]);

    await tester.pumpWidget(_app(qc));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Expand queue'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('#'), findsOneWidget); // column header
    expect(find.text('7'), findsOneWidget);
    expect(find.text('2-5'), findsOneWidget);
    // The queue-position column is unaffected: three rows, numbered 1..3.
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });
}
