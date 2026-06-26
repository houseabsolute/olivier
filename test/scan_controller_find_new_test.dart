import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/src/rust/catalog/scan.dart';
import 'package:olivier/state/enrich_controller.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/scan_controller.dart';

/// No-op enrich so the post-drain auto-enrich doesn't hit the FFI. Inherits
/// EnrichController.build() (a pure initial-state return); if build() ever does
/// I/O, also override it to return the initial EnrichState.
class _NoopEnrich extends EnrichController {
  @override
  Future<void> enrich({bool force = false, bool clearCache = false}) async {}
}

ScanProgress _done() => ScanProgress(
    filesSeen: BigInt.zero, filesChanged: BigInt.zero, current: '', done: true);

void main() {
  Future<List<({List<String> roots, bool newOnly})>> runAction(
    void Function(ScanController c) action,
  ) async {
    final calls = <({List<String> roots, bool newOnly})>[];
    final called = Completer<void>();
    final container = ProviderContainer(overrides: [
      listRootsFnProvider.overrideWithValue(() async => ['/m']),
      scanLibraryFnProvider.overrideWithValue((roots, newOnly) {
        calls.add((roots: roots, newOnly: newOnly));
        if (!called.isCompleted) called.complete();
        return Stream.value(_done());
      }),
      enrichControllerProvider.overrideWith(_NoopEnrich.new),
    ]);
    addTearDown(container.dispose);

    final c = container.read(scanControllerProvider.notifier);
    await c.loadRoots(); // seeds state.roots = ['/m']
    action(c);
    await called.future;
    await Future<void>.delayed(Duration.zero); // let the drain settle
    return calls;
  }

  test('findNewFiles scans each root with newOnly: true', () async {
    final calls = await runAction((c) => c.findNewFiles());
    expect(calls, hasLength(1));
    expect(calls.single.roots, ['/m']);
    expect(calls.single.newOnly, isTrue);
  });

  test('rescanAll scans each root with newOnly: false', () async {
    final calls = await runAction((c) => c.rescanAll());
    expect(calls, hasLength(1));
    expect(calls.single.roots, ['/m']);
    expect(calls.single.newOnly, isFalse);
  });
}
