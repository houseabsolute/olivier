import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:olivier/src/rust/api/tags.dart';
import 'package:olivier/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async => RustLib.init());

  test('reads tags from a flac fixture through the bridge', () async {
    final t = await readTrackTags(path: 'rust/tests/fixtures/sample.flac');
    expect(t.title, '正しい街');
    expect(t.albumArtist, '椎名林檎');
    expect(t.recordingMbid, 'aaaaaaaa-0000-0000-0000-000000000001');
  });
}
