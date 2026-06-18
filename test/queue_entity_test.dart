import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/audio/queue_entity.dart';

void main() {
  final fns = EntityPathFns(
    artistPaths: (mbid) async => ['/m/$mbid-1', '/m/$mbid-2'],
    albumPaths: (releaseMbid) async => ['/m/$releaseMbid-a'],
    trackPath: (id) async => id == 7 ? '/m/track7' : null,
  );

  test('artist entity resolves via artistPaths', () async {
    final paths = await resolveEntityPaths(
      const QueueEntityRef.artist('art1'),
      fns,
    );
    expect(paths, ['/m/art1-1', '/m/art1-2']);
  });

  test('album entity resolves via albumPaths', () async {
    final paths = await resolveEntityPaths(
      const QueueEntityRef.album('rel1'),
      fns,
    );
    expect(paths, ['/m/rel1-a']);
  });

  test('track entity resolves via trackPath; missing → empty', () async {
    expect(
      await resolveEntityPaths(const QueueEntityRef.track(7), fns),
      ['/m/track7'],
    );
    expect(
      await resolveEntityPaths(const QueueEntityRef.track(99), fns),
      isEmpty,
    );
  });
}
