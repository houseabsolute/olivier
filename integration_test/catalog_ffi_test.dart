import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:olivier/src/rust/api/catalog.dart';
import 'package:olivier/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async => RustLib.init());

  test('scan-stream + browse queries round-trip through the bridge', () async {
    final tempDir = await Directory.systemTemp.createTemp('catalog_ffi_test_');
    addTearDown(() => tempDir.delete(recursive: true));

    final musicDir = await Directory('${tempDir.path}/music').create();
    final dbPath = '${tempDir.path}/test.db';

    // Copy fixtures into temp music dir.
    final projectRoot = Directory.current.path;
    final fixturesDir = '$projectRoot/rust/tests/fixtures';
    await File('$fixturesDir/sample.flac').copy('${musicDir.path}/sample.flac');
    await File('$fixturesDir/sample.mp3').copy('${musicDir.path}/sample.mp3');

    // Scan the library via the streaming FFI function.
    await for (final p in scanLibrary(
        dbPath: dbPath, roots: [musicDir.path], newOnly: false)) {
      if (p.done) break;
    }

    // Artists page should contain at least one artist.
    final artists = await listArtists(dbPath: dbPath, after: null, limit: 50);
    expect(artists.length, greaterThanOrEqualTo(1));

    // Albums for the first artist.
    final artist = artists.first;
    final albums =
        await listAlbums(dbPath: dbPath, albumArtistMbid: artist.mbid);
    expect(albums.length, greaterThanOrEqualTo(1));

    // Tracks for the first album.
    final album = albums.first;
    final tracks =
        await listTracks(dbPath: dbPath, releaseMbid: album.releaseMbid);
    expect(tracks.length, greaterThanOrEqualTo(1));
  });
}
