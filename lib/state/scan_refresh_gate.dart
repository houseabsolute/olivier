/// How many newly-changed files to scan between live browse-view refreshes.
const kScanRefreshEvery = 50;

/// Gates the periodic browse refresh during a scan: fires once per [every]
/// newly-changed files. Stateful for one scan call; create a fresh instance per
/// `scanLibrary` call. The catalog scanner is invoked one root per call, so the
/// changed-count this gate tracks starts at 0 each time.
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
