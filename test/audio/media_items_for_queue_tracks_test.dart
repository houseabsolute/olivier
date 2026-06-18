import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/src/rust/catalog/schema.dart';

/// Pure host-VM coverage for the QueueTrack -> MediaItem mapping that seeds the
/// now-playing bar / MPRIS metadata. No FFI, no platform channels.
void main() {
  test('maps title/artist/album/duration and the extras', () {
    final items = mediaItemsForQueueTracks([
      QueueTrack(
        path: '/music/a.flac',
        trackId: 42,
        title: 'Song A',
        artist: 'Artist A',
        album: 'Album A',
        lengthMs: BigInt.from(123456),
        titleTranslit: 'Song A translit',
        titleTranslate: 'Song A translate',
      ),
    ]);

    expect(items, hasLength(1));
    final item = items.single;
    expect(item.id, '/music/a.flac');
    expect(item.title, 'Song A');
    expect(item.artist, 'Artist A');
    expect(item.album, 'Album A');
    expect(item.duration, const Duration(milliseconds: 123456));
    expect(item.extras?['trackId'], 42);
    expect(item.extras?['titleTranslit'], 'Song A translit');
    expect(item.extras?['titleTranslate'], 'Song A translate');
  });

  test('empty album maps to null (so MPRIS shows no album)', () {
    final items = mediaItemsForQueueTracks([
      const QueueTrack(path: '/music/b.flac', title: 'B', album: ''),
    ]);
    expect(items.single.album, isNull);
  });

  test('null lengthMs maps to null duration', () {
    final items = mediaItemsForQueueTracks([
      const QueueTrack(path: '/music/c.flac', title: 'C', album: 'Album C'),
    ]);
    expect(items.single.duration, isNull);
  });

  test('absent trackId omits the trackId extra (play tracking skips it)', () {
    final items = mediaItemsForQueueTracks([
      const QueueTrack(
        path: '/music/d.flac',
        title: 'D',
        album: 'Album D',
        titleTranslit: 'tl',
        titleTranslate: 'tt',
      ),
    ]);
    final extras = items.single.extras!;
    expect(extras.containsKey('trackId'), isFalse);
    // The bilingual-title extras are always present (may be null).
    expect(extras.containsKey('titleTranslit'), isTrue);
    expect(extras.containsKey('titleTranslate'), isTrue);
  });

  test('null artist passes through as null', () {
    final items = mediaItemsForQueueTracks([
      const QueueTrack(path: '/music/e.flac', title: 'E', album: 'Album E'),
    ]);
    expect(items.single.artist, isNull);
  });

  test('maps multiple tracks 1:1 in order', () {
    final items = mediaItemsForQueueTracks([
      const QueueTrack(path: '/1.flac', title: 'One', album: 'X'),
      const QueueTrack(path: '/2.flac', title: 'Two', album: 'X'),
      const QueueTrack(path: '/3.flac', title: 'Three', album: 'X'),
    ]);
    expect(items.map((i) => i.id).toList(), ['/1.flac', '/2.flac', '/3.flac']);
    expect(items.map((i) => i.title).toList(), ['One', 'Two', 'Three']);
  });

  test('empty input yields empty output', () {
    expect(mediaItemsForQueueTracks(const <QueueTrack>[]), isEmpty);
  });
}
