import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/state/scan_refresh_gate.dart';

void main() {
  test('fires once per `every` changed files, advancing the mark', () {
    final gate = ScanRefreshGate(50);
    expect(gate.shouldRefresh(10), isFalse);
    expect(gate.shouldRefresh(49), isFalse);
    expect(gate.shouldRefresh(50), isTrue); // crossed 50
    expect(gate.shouldRefresh(75), isFalse); // only 25 since last fire
    expect(gate.shouldRefresh(100), isTrue); // crossed another 50
  });

  test('a no-change scan never fires', () {
    final gate = ScanRefreshGate(50);
    expect(gate.shouldRefresh(0), isFalse);
    expect(gate.shouldRefresh(0), isFalse);
  });

  test('default threshold is kScanRefreshEvery', () {
    final gate = ScanRefreshGate();
    expect(gate.shouldRefresh(kScanRefreshEvery - 1), isFalse);
    expect(gate.shouldRefresh(kScanRefreshEvery), isTrue);
  });
}
