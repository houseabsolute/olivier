import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/api/sync.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/sync_import_controller.dart';

ImportResult _result({
  bool imported = true,
  String reason = '',
  int files = 5,
  int covers = 2,
}) =>
    ImportResult(
      imported: imported,
      reason: reason,
      files: files,
      coversCopied: covers,
    );

class _Call {
  _Call(this.srcDir, this.dbPath, this.cacheDir);
  final String srcDir;
  final String dbPath;
  final String? cacheDir;
}

ProviderContainer _container({
  Map<String, String> settings = const {},
  List<_Call>? calls,
  Future<ImportResult> Function(_Call)? onImport,
  bool granted = true,
  List<String>? permissionCalls,
}) {
  final store = {...settings};
  return ProviderContainer(overrides: [
    dbPathProvider.overrideWithValue('/data/olivier.db'),
    getSettingFnProvider.overrideWithValue((key) async => store[key]),
    setSettingFnProvider.overrideWithValue((key, value) async {
      store[key] = value;
    }),
    importCacheDirFnProvider.overrideWithValue(() async => '/cache'),
    storagePermissionStatusFnProvider.overrideWithValue(() async {
      permissionCalls?.add('status');
      return granted;
    }),
    storagePermissionFnProvider.overrideWithValue(() async {
      permissionCalls?.add('request');
      return granted;
    }),
    importSnapshotFnProvider.overrideWithValue(
      ({required srcDir, required dbPath, cacheDir}) {
        final call = _Call(srcDir, dbPath, cacheDir);
        calls?.add(call);
        return onImport?.call(call) ?? Future.value(_result());
      },
    ),
  ]);
}

void main() {
  test('imports from the default sync folder', () async {
    final calls = <_Call>[];
    final c = _container(calls: calls);
    addTearDown(c.dispose);

    await c.read(syncImportControllerProvider.notifier).importIfNewer();

    expect(calls.single.srcDir, defaultSyncSourceDir);
    expect(calls.single.dbPath, '/data/olivier.db');
    expect(calls.single.cacheDir, '/cache');
    final state = c.read(syncImportControllerProvider);
    expect(state.running, isFalse);
    expect(state.lastResult, contains('5 tracks'));
    expect(state.lastError, isNull);
  });

  test('a configured source folder overrides the default', () async {
    final calls = <_Call>[];
    final c = _container(
      settings: {syncSourceDirKey: '/storage/emulated/0/Sync/Music'},
      calls: calls,
    );
    addTearDown(c.dispose);

    await c.read(syncImportControllerProvider.notifier).importIfNewer();

    expect(calls.single.srcDir, '/storage/emulated/0/Sync/Music');
  });

  test('reports the skip reason when there is nothing new', () async {
    final c = _container(
      onImport: (_) async =>
          _result(imported: false, reason: 'already imported'),
    );
    addTearDown(c.dispose);

    await c.read(syncImportControllerProvider.notifier).importIfNewer();

    final state = c.read(syncImportControllerProvider);
    expect(state.lastResult, 'already imported');
    expect(state.lastError, isNull, reason: 'nothing new is not a failure');
  });

  test('startup never asks for the permission, only checks it', () async {
    final permissionCalls = <String>[];
    final c = _container(permissionCalls: permissionCalls);
    addTearDown(c.dispose);

    await c.read(syncImportControllerProvider.notifier).importIfNewer();

    expect(permissionCalls, isNot(contains('request')),
        reason: 'a cold start must not block on a system permission screen');
    expect(permissionCalls, contains('status'));
  });

  test('the Settings button does ask for the permission', () async {
    final permissionCalls = <String>[];
    final c = _container(permissionCalls: permissionCalls);
    addTearDown(c.dispose);

    await c
        .read(syncImportControllerProvider.notifier)
        .importIfNewer(interactive: true);

    expect(permissionCalls, contains('request'));
  });

  test('without storage access it reports why and does not call the FFI',
      () async {
    final calls = <_Call>[];
    final c = _container(granted: false, calls: calls);
    addTearDown(c.dispose);

    await c.read(syncImportControllerProvider.notifier).importIfNewer();

    expect(calls, isEmpty);
    final state = c.read(syncImportControllerProvider);
    expect(state.hasStoragePermission, isFalse);
    expect(state.lastError, contains('Storage access'));
    expect(state.running, isFalse);
  });

  test('surfaces a failed import without wedging the busy flag', () async {
    final c = _container(onImport: (_) async => throw StateError('bad db'));
    addTearDown(c.dispose);

    await c.read(syncImportControllerProvider.notifier).importIfNewer();

    final state = c.read(syncImportControllerProvider);
    expect(state.running, isFalse);
    expect(state.lastError, contains('bad db'));
  });

  test('a second import while one is running is ignored', () async {
    final calls = <_Call>[];
    final gate = Completer<ImportResult>();
    final c = _container(calls: calls, onImport: (_) => gate.future);
    addTearDown(c.dispose);
    final notifier = c.read(syncImportControllerProvider.notifier);

    final first = notifier.importIfNewer();
    await Future<void>.delayed(Duration.zero);
    await notifier.importIfNewer();
    gate.complete(_result());
    await first;

    expect(calls.length, 1);
  });

  test('the permission is checked as soon as the controller is watched',
      () async {
    // Otherwise Settings shows "access is needed" on every launch, even when
    // it was granted long ago.
    final permissionCalls = <String>[];
    final c = _container(permissionCalls: permissionCalls);
    addTearDown(c.dispose);

    c.read(syncImportControllerProvider);
    await Future<void>.delayed(Duration.zero);

    expect(permissionCalls, ['status']);
    expect(c.read(syncImportControllerProvider).hasStoragePermission, isTrue);
  });

  test('refreshPermission reflects the current grant', () async {
    final c = _container(granted: false);
    addTearDown(c.dispose);

    await c.read(syncImportControllerProvider.notifier).refreshPermission();

    expect(c.read(syncImportControllerProvider).hasStoragePermission, isFalse);
  });
}
