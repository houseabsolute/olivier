/// How many newly-changed files to scan between live browse-view refreshes.
const kScanRefreshEvery = 50;

/// Gates the periodic browse refresh during a scan: fires once per [every]
/// newly-changed files. Stateful across one root's scan; create a fresh instance
/// per root (the scanner's changed-count restarts at 0 each root).
class ScanRefreshGate {
  ScanRefreshGate([this.every = kScanRefreshEvery]);

  final int every;
  int _last = 0;

  /// True when [changedSoFar] has advanced by at least [every] since this last
  /// returned true (and then advances the high-water mark). A scan with no
  /// new/changed files never fires.
  bool shouldRefresh(int changedSoFar) {
    if (changedSoFar - _last >= every) {
      _last = changedSoFar;
      return true;
    }
    return false;
  }
}
