import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/catalog/queue_panel.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/queue_provider.dart';

QueueTrack _qt(String title) =>
    QueueTrack(path: '/m/$title', title: title, album: 'Album', addedAt: 0);

class _StubQueue extends QueueNotifier {
  _StubQueue(this._view);
  final QueueView _view;
  @override
  Future<QueueView> build() async => _view;
}

Widget _app(QueueView view) => ProviderScope(
      overrides: [
        getSettingFnProvider.overrideWithValue((key) async => null),
        queueProvider.overrideWith(() => _StubQueue(view)),
      ],
      child: const MaterialApp(home: Scaffold(body: QueuePanel())),
    );

void main() {
  testWidgets('header shows the real count and up-next title', (tester) async {
    await tester.pumpWidget(_app(QueueView(
      tracks: [_qt('One'), _qt('Two'), _qt('Three')],
      currentIndex: 0,
      shuffled: false,
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('3 tracks'), findsOneWidget);
    // current is index 0 → "up next" is the following entry, "Two".
    expect(find.textContaining('Two'), findsOneWidget);
  });

  testWidgets('empty queue header shows 0 tracks and no up-next',
      (tester) async {
    await tester.pumpWidget(_app(QueueView.empty));
    await tester.pumpAndSettle();
    expect(find.textContaining('0 tracks'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
