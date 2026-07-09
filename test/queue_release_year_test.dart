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

class _StubQueue extends QueueNotifier {
  _StubQueue(this._v);
  final QueueView _v;
  @override
  Future<QueueView> build() async => _v;
}

QueueTrack _track({String? originalYear, String? reissueYear}) => QueueTrack(
      path: '/a.flac',
      title: 'Song',
      album: 'Dark Side',
      addedAt: 0,
      originalYear: originalYear,
      reissueYear: reissueYear,
    );

Future<void> _pumpExpanded(WidgetTester tester, QueueTrack track) async {
  final qc = QueueController.withPlayer(FakeQueuePlayer(),
      dbPath: ':memory:', saveQueue: (_) async {});
  await qc.append([track.path]);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      getSettingFnProvider.overrideWithValue((_) async => null),
      queueControllerProvider.overrideWithValue(qc),
      queueProvider.overrideWith(
        () => _StubQueue(
            QueueView(tracks: [track], currentIndex: 0, shuffled: false)),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: QueuePanel())),
  ));
  await tester.pump();
  await tester.pump();
  await tester.tap(find.byTooltip('Expand queue'));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('appends the original year to the album', (tester) async {
    await _pumpExpanded(
        tester, _track(originalYear: '1973', reissueYear: '2011'));
    // Year-suffixed label is unique to the expanded row (the header, if it
    // shows the album at all, shows it without the year).
    expect(find.text('Dark Side (1973)'), findsOneWidget);
  });

  testWidgets('falls back to the reissue year when original is null',
      (tester) async {
    await _pumpExpanded(
        tester, _track(originalYear: null, reissueYear: '2011'));
    expect(find.text('Dark Side (2011)'), findsOneWidget);
  });

  testWidgets('shows the bare album when no year is known', (tester) async {
    await _pumpExpanded(tester, _track());
    // No parenthetical year was appended anywhere.
    expect(find.textContaining('Dark Side ('), findsNothing);
  });
}
