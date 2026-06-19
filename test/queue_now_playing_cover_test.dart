import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/cover_providers.dart';
import 'package:olivier/state/queue_provider.dart';
import 'package:olivier/widgets/album_cover.dart';

QueueTrack _track(String path, String title) => QueueTrack(
      path: path,
      title: title,
      album: '',
      addedAt: 0,
      lastPlayed: null,
      titleTranslit: null,
      titleTranslate: null,
    );

void main() {
  testWidgets('queue header shows a PathCover for the current track',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        queueProvider.overrideWith(() => _FakeQueue(QueueView(
              tracks: [_track('/m/a.flac', 'A'), _track('/m/b.flac', 'B')],
              currentIndex: 1,
              shuffled: false,
            ))),
        coverForPathFnProvider.overrideWithValue((_) async => null),
      ],
      child: const MaterialApp(home: Scaffold(body: QueuePanel())),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.byType(PathCover), findsOneWidget);
  });

  testWidgets('queue header shows no cover when nothing is playing',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        queueProvider.overrideWith(() => _FakeQueue(QueueView.empty)),
        coverForPathFnProvider.overrideWithValue((_) async => null),
      ],
      child: const MaterialApp(home: Scaffold(body: QueuePanel())),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.byType(PathCover), findsNothing);
  });

  // Regression: the cheap index-update path in queue_provider can momentarily
  // emit a QueueView whose currentIndex is set while tracks is still the stale
  // (shorter/empty) cached list — e.g. right after appending an album, before
  // _resolve() repopulates tracks. Indexing tracks[currentIndex] unguarded threw
  // a RangeError during build, painting Flutter's red ErrorWidget for a frame
  // (a full-app red flash). The header must tolerate an out-of-range index.
  testWidgets('queue header does not crash when currentIndex is out of range',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        queueProvider.overrideWith(() => _FakeQueue(const QueueView(
              tracks: [],
              currentIndex: 0,
              shuffled: false,
            ))),
        coverForPathFnProvider.overrideWithValue((_) async => null),
      ],
      child: const MaterialApp(home: Scaffold(body: QueuePanel())),
    ));
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(PathCover), findsNothing);
  });
}

class _FakeQueue extends QueueNotifier {
  _FakeQueue(this._view);
  final QueueView _view;
  @override
  Future<QueueView> build() async => _view;
}
