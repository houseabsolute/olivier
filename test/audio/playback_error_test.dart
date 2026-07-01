import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';

void main() {
  group('resolvePlaybackError', () {
    test('detail + next track: message includes detail, action skipToNext', () {
      final o = resolvePlaybackError(
        title: 'Song',
        detail: 'mp3float: Header missing',
        hasNext: true,
      );
      expect(o.message, 'Couldn\'t play "Song": mp3float: Header missing');
      expect(o.action, PlaybackErrorAction.skipToNext);
    });

    test('no next track: action stop', () {
      final o = resolvePlaybackError(title: 'Song', detail: 'boom', hasNext: false);
      expect(o.action, PlaybackErrorAction.stop);
    });

    test('null detail: no trailing colon', () {
      final o = resolvePlaybackError(title: 'Song', detail: null, hasNext: true);
      expect(o.message, 'Couldn\'t play "Song"');
    });

    test('empty detail: no trailing colon', () {
      final o = resolvePlaybackError(title: 'Song', detail: '', hasNext: true);
      expect(o.message, 'Couldn\'t play "Song"');
    });

    test('title used verbatim; stop when no next', () {
      final o = resolvePlaybackError(title: 'this track', detail: null, hasNext: false);
      expect(o.message, 'Couldn\'t play "this track"');
      expect(o.action, PlaybackErrorAction.stop);
    });
  });
}
