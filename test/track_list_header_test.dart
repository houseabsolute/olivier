import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/track_column.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

import 'support/fake_queue_player.dart';

final _tracks = [
  Track(id: 1, disc: 1, position: 1, title: 'First Song', addedAt: 0),
  Track(id: 2, disc: 1, position: 2, title: 'Second Song', addedAt: 0),
];

class _StubAlbum extends SelectedAlbum {
  @override
  String? build() => 'rel-1';
}

ProviderScope _app(QueueController qc) => ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        tracksProvider.overrideWith((ref) => _tracks),
        selectedAlbumProvider.overrideWith(() => _StubAlbum()),
        queueControllerProvider.overrideWithValue(qc),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 600, height: 800, child: TrackColumn()),
        ),
      ),
    );

void main() {
  testWidgets('header row shows # / Title / Length / Added / Played labels',
      (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/x.db', saveQueue: (_) async {});
    await tester.pumpWidget(_app(qc));
    await tester.pump();

    expect(find.text('#'), findsOneWidget);
    expect(find.text('Title'), findsOneWidget);
    expect(find.text('Length'), findsOneWidget);
    expect(find.text('Added'), findsOneWidget);
    expect(find.text('Played'), findsOneWidget);
  });

  testWidgets('track position number renders in its own column (not prefixed)',
      (tester) async {
    final qc = QueueController.withPlayer(FakeQueuePlayer(),
        dbPath: '/x.db', saveQueue: (_) async {});
    await tester.pumpWidget(_app(qc));
    await tester.pump();

    // Position number as a standalone text (no ". " suffix).
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    // Track titles should NOT include the old "1. " prefix.
    expect(find.text('First Song'), findsOneWidget);
    expect(find.text('Second Song'), findsOneWidget);
    expect(find.textContaining('1. '), findsNothing);
    expect(find.textContaining('2. '), findsNothing);
  });
}
