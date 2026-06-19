import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/state/cover_providers.dart';
import 'package:olivier/widgets/album_cover.dart';

void main() {
  testWidgets(
      'AlbumCover renders an Image (not the placeholder) when a cover resolves',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        coverForReleaseFnProvider
            .overrideWithValue((_) async => '/tmp/olivier-test-cover.png'),
      ],
      child: const MaterialApp(
        home: AlbumCover(releaseMbid: 'rel', size: 40),
      ),
    ));
    // Two pumps resolve the FutureProvider and rebuild with the path. We do NOT
    // pumpAndSettle (Image.file's async decode never settles in fake-async), and
    // we use a fake path with no real file I/O (real dart:io in the fake-async
    // zone can hang the test). The placeholder branch is a Container+Icon with
    // NO Image widget, so finding an Image proves the cover branch was taken.
    await tester.pump();
    await tester.pump();

    // find.byType(Image) is timing-robust: the Image widget stays in the tree
    // even if its (fake-path) load later errors into errorBuilder, and the
    // placeholder branch builds no Image at all.
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('AlbumCover shows the placeholder when there is no cover',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        coverForReleaseFnProvider.overrideWithValue((_) async => null),
      ],
      child: const MaterialApp(
        home: AlbumCover(releaseMbid: 'rel', size: 40),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.album), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}
