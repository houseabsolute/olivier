import 'dart:async';

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/api/sync.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/sync_export_controller.dart';

SnapshotResult _result({int files = 2, int covers = 1}) => SnapshotResult(
      dbPath: '/sync/olivier-sync.db',
      files: files,
      coversCopied: covers,
    );

/// Everything the stubbed FFI call was handed, so tests can assert the
/// controller passes the right destination and cache dir — not just mappings.
class _Call {
  _Call(this.destDir, this.cacheDir, this.mappings);
  final String destDir;
  final String? cacheDir;
  final List<RootMapping> mappings;
}

ProviderContainer _container({
  Map<String, String> settings = const {},
  List<_Call>? calls,
  Future<SnapshotResult> Function(_Call)? onExport,
  String? cacheDir = '/cache',
  Map<String, String>? stored,
}) {
  final store = stored ?? {...settings};
  return ProviderContainer(overrides: [
    dbPathProvider.overrideWithValue(':memory:'),
    getSettingFnProvider.overrideWithValue((key) async => store[key]),
    setSettingFnProvider.overrideWithValue((key, value) async {
      store[key] = value;
    }),
    cacheDirFnProvider.overrideWithValue(() async => cacheDir),
    exportSnapshotFnProvider.overrideWithValue(
      ({required destDir, cacheDir, required mappings}) {
        final call = _Call(destDir, cacheDir, mappings);
        calls?.add(call);
        return onExport?.call(call) ?? Future.value(_result());
      },
    ),
  ]);
}

void main() {
  group('default phone location', () {
    test('a single folder maps straight onto the phone root', () {
      // The common Syncthing setup. Appending the folder's own name here would
      // export cleanly and produce a catalog of dead links.
      expect(defaultPhoneFor('/home/me/Music', ['/home/me/Music']),
          defaultPhoneRoot);
      expect(
          defaultPhoneFor(
              '/home/autarch/mnt/music', ['/home/autarch/mnt/music']),
          defaultPhoneRoot);
    });

    test('several folders each keep their own name beneath it', () {
      final roots = ['/home/me/Music', '/mnt/archive/FLAC'];
      expect(defaultPhoneFor(roots[0], roots), '$defaultPhoneRoot/Music');
      expect(defaultPhoneFor(roots[1], roots), '$defaultPhoneRoot/FLAC');
    });

    test('a degenerate root falls back instead of throwing', () {
      // add_root trims trailing slashes, so adding "/" stores the empty string.
      for (final root in ['/', '']) {
        expect(defaultPhoneFor(root, [root, '/other']), defaultPhoneRoot);
      }
    });
  });

  group('mapping problems', () {
    test('accepts a well-formed mapping', () {
      expect(
        mappingProblem(
            [const RootMapping(desktop: '/a', phone: '/storage/Music')]),
        isNull,
      );
    });

    test('rejects a relative phone path', () {
      final problem = mappingProblem(
          [const RootMapping(desktop: '/a', phone: 'sdcard/Music')]);
      expect(problem, contains('absolute path'));
      expect(problem, contains('/a'), reason: 'must name the offending folder');
    });

    test('rejects two folders landing in the same place', () {
      final problem = mappingProblem([
        const RootMapping(desktop: '/a/Music', phone: '/storage/Music'),
        const RootMapping(desktop: '/b/Music', phone: '/storage/Music'),
      ]);
      expect(problem, contains('/a/Music'));
      expect(problem, contains('/b/Music'));
    });

    test('rejects an empty library', () {
      expect(mappingProblem([]), contains('No music folders'));
    });
  });

  test('hydrates persisted settings', () async {
    final container = _container(settings: {
      syncDestDirKey: '/sync/olivier',
      syncPhoneRootsKey: jsonEncode({'/home/me/Music': '/sdcard/Tunes'}),
    });
    addTearDown(container.dispose);

    await container.read(syncExportControllerProvider.notifier).hydrate();
    final state = container.read(syncExportControllerProvider);

    expect(state.destDir, '/sync/olivier');
    expect(state.phoneRoots, {'/home/me/Music': '/sdcard/Tunes'});
  });

  test('a corrupt phone-roots setting falls back to defaults', () async {
    final container = _container(settings: {
      syncDestDirKey: '/sync',
      syncPhoneRootsKey: 'not json at all',
    });
    addTearDown(container.dispose);

    await container.read(syncExportControllerProvider.notifier).hydrate();

    expect(container.read(syncExportControllerProvider).phoneRoots, isEmpty);
  });

  test('a late hydrate does not overwrite a user edit', () async {
    final container = _container(settings: {syncDestDirKey: '/stored'});
    addTearDown(container.dispose);
    final notifier = container.read(syncExportControllerProvider.notifier);

    // Simulates build()'s unawaited hydrate still in flight when the user picks
    // a folder: start the read, edit, then let the hydrate land.
    final inFlight = notifier.hydrate();
    await notifier.setDestDir('/chosen-by-user');
    await inFlight;

    expect(container.read(syncExportControllerProvider).destDir,
        '/chosen-by-user');
  });

  test('cannot export before a destination is chosen', () async {
    final calls = <_Call>[];
    final container = _container(calls: calls);
    addTearDown(container.dispose);
    final notifier = container.read(syncExportControllerProvider.notifier);
    await notifier.hydrate();

    expect(notifier.canExport(['/home/me/Music']), isFalse);
    await notifier.export(['/home/me/Music']);

    expect(calls, isEmpty);
    expect(container.read(syncExportControllerProvider).lastResult, isNull);
    expect(container.read(syncExportControllerProvider).lastError, isNull);
  });

  test('cannot export an empty library', () async {
    final container = _container(settings: {syncDestDirKey: '/sync'});
    addTearDown(container.dispose);
    final notifier = container.read(syncExportControllerProvider.notifier);
    await notifier.hydrate();

    expect(notifier.canExport([]), isFalse);
  });

  test('passes the destination, cache dir and mappings through', () async {
    final calls = <_Call>[];
    final container = _container(
      settings: {syncDestDirKey: '/sync/dest'},
      calls: calls,
      onExport: (_) async => _result(files: 42, covers: 7),
    );
    addTearDown(container.dispose);
    final notifier = container.read(syncExportControllerProvider.notifier);
    await notifier.hydrate();

    await notifier.export(['/home/me/Music']);

    expect(calls.single.destDir, '/sync/dest');
    expect(calls.single.cacheDir, '/cache');
    expect(calls.single.mappings.single.desktop, '/home/me/Music');
    expect(calls.single.mappings.single.phone, defaultPhoneRoot);
    final state = container.read(syncExportControllerProvider);
    expect(state.exporting, isFalse);
    expect(state.lastResult, contains('42 tracks'));
    expect(state.lastResult, contains('7 covers'));
    expect(state.lastError, isNull);
  });

  test('an edited phone location reaches the export', () async {
    final calls = <_Call>[];
    final container =
        _container(settings: {syncDestDirKey: '/sync'}, calls: calls);
    addTearDown(container.dispose);
    final notifier = container.read(syncExportControllerProvider.notifier);
    await notifier.hydrate();

    await notifier.setPhoneRoot('/home/me/Music', '/sdcard/Tunes');
    await notifier.export(['/home/me/Music']);

    expect(calls.single.mappings.single.phone, '/sdcard/Tunes');
  });

  test('an edited location survives a round trip through settings', () async {
    final store = {syncDestDirKey: '/sync'};
    final container = _container(stored: store);
    addTearDown(container.dispose);
    final notifier = container.read(syncExportControllerProvider.notifier);
    await notifier.hydrate();
    await notifier.setPhoneRoot('/home/me/Music', '/sdcard/Tunes');

    // A fresh controller over the same store reads it back.
    final second = _container(stored: store);
    addTearDown(second.dispose);
    await second.read(syncExportControllerProvider.notifier).hydrate();

    expect(second.read(syncExportControllerProvider).phoneRoots,
        {'/home/me/Music': '/sdcard/Tunes'});
  });

  test('a null cache dir is passed through rather than failing', () async {
    final calls = <_Call>[];
    final container = _container(
      settings: {syncDestDirKey: '/sync'},
      calls: calls,
      cacheDir: null,
    );
    addTearDown(container.dispose);
    final notifier = container.read(syncExportControllerProvider.notifier);
    await notifier.hydrate();

    await notifier.export(['/home/me/Music']);

    expect(calls.single.cacheDir, isNull);
    expect(container.read(syncExportControllerProvider).lastError, isNull);
  });

  test('refuses a mapping that would collide, without calling the FFI',
      () async {
    final calls = <_Call>[];
    final container =
        _container(settings: {syncDestDirKey: '/sync'}, calls: calls);
    addTearDown(container.dispose);
    final notifier = container.read(syncExportControllerProvider.notifier);
    await notifier.hydrate();
    await notifier.setPhoneRoot('/a/Music', '/sdcard/Music');
    await notifier.setPhoneRoot('/b/Music', '/sdcard/Music');

    await notifier.export(['/a/Music', '/b/Music']);

    expect(calls, isEmpty, reason: 'caught before the FFI, not after');
    expect(container.read(syncExportControllerProvider).lastError,
        contains('both go to'));
  });

  test('a second export while one is in flight is ignored', () async {
    final calls = <_Call>[];
    final gate = Completer<SnapshotResult>();
    final container = _container(
      settings: {syncDestDirKey: '/sync'},
      calls: calls,
      onExport: (_) => gate.future,
    );
    addTearDown(container.dispose);
    final notifier = container.read(syncExportControllerProvider.notifier);
    await notifier.hydrate();

    final first = notifier.export(['/home/me/Music']);
    await Future<void>.delayed(Duration.zero);
    await notifier.export(['/home/me/Music']);
    gate.complete(_result());
    await first;

    expect(calls.length, 1, reason: 're-entrant export must be a no-op');
  });

  test('surfaces an export failure without leaving the busy flag set',
      () async {
    final container = _container(
      settings: {syncDestDirKey: '/sync'},
      onExport: (_) async => throw StateError('disk full'),
    );
    addTearDown(container.dispose);
    final notifier = container.read(syncExportControllerProvider.notifier);
    await notifier.hydrate();

    await notifier.export(['/home/me/Music']);

    final state = container.read(syncExportControllerProvider);
    expect(state.exporting, isFalse,
        reason: 'a failed export must not wedge the UI');
    expect(state.lastError, contains('disk full'));
    expect(state.lastResult, isNull);
  });

  test('a stale result is cleared when the next export starts', () async {
    final container = _container(
      settings: {syncDestDirKey: '/sync'},
      onExport: (_) async => throw StateError('boom'),
    );
    addTearDown(container.dispose);
    final notifier = container.read(syncExportControllerProvider.notifier);
    await notifier.hydrate();

    await notifier.export(['/home/me/Music']);
    expect(container.read(syncExportControllerProvider).lastError, isNotNull);

    await notifier.export([]);
    final state = container.read(syncExportControllerProvider);
    expect(state.lastResult, isNull);
    expect(state.lastError, contains('No music folders'));
  });
}
