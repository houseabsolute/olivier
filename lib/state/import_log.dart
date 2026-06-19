import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/state/providers.dart';

/// Path of the decision log: a sibling of the SQLite DB. Matches the Rust side
/// (`DecisionLog::for_db` → `<dir>/import-log.log`).
final importLogPathProvider = Provider<String>((ref) {
  final db = ref.watch(dbPathProvider);
  return '${File(db).parent.path}/import-log.log';
});

/// Reads the whole decision log (empty string if it doesn't exist yet).
/// Injectable so the viewer is testable without a real file.
typedef ImportLogFn = Future<String> Function();

final importLogFnProvider = Provider<ImportLogFn>((ref) {
  final path = ref.watch(importLogPathProvider);
  return () async {
    final f = File(path);
    if (!await f.exists()) return '';
    return f.readAsString();
  };
});

/// Truncates the decision log to empty.
typedef ClearImportLogFn = Future<void> Function();

final clearImportLogFnProvider = Provider<ClearImportLogFn>((ref) {
  final path = ref.watch(importLogPathProvider);
  return () async {
    final f = File(path);
    if (await f.exists()) await f.writeAsString('');
  };
});
