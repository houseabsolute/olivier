import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:olivier/audio/queue_player.dart';

/// Shared [QueuePlayer] test double. A real just_audio AudioPlayer needs the
/// media_kit platform channel and cannot run under headless `flutter test`, so
/// unit tests inject this. It mirrors the incremental ops into [sources] and
/// records remove/seek calls plus a settable current index so the queue logic
/// (including the Slice-5 shuffle index translation) can be asserted.
class FakeQueuePlayer implements QueuePlayer {
  /// The fake's view of the player's source order, mutated by the incremental
  /// ops so tests can assert it ended up 1:1 with QueueController._playOrder.
  final List<String> sources = [];

  /// Every removeAudioSourceAt(index) the controller issued, in order.
  final List<int> removedIndexes = [];

  /// Every seek(position, index:) the controller issued, in order.
  final List<({Duration position, int? index})> seeks = [];

  bool played = false;

  /// True once [stop] has been called (and not since superseded by a rebuild).
  bool stopCalled = false;

  int? _currentIndex = 0;
  final _indexCtrl = StreamController<int?>.broadcast();

  String _path(AudioSource s) => (s as UriAudioSource).uri.toFilePath();

  @override
  int? get currentIndex => _currentIndex;

  /// Test hook: simulate the player advancing to a source position.
  void setCurrentIndex(int? i) {
    _currentIndex = i;
    _indexCtrl.add(i);
  }

  @override
  Stream<int?> get currentIndexStream => _indexCtrl.stream;

  @override
  Future<void> addAudioSource(AudioSource source) async {
    sources.add(_path(source));
  }

  @override
  Future<void> insertAudioSource(int index, AudioSource source) async {
    sources.insert(index, _path(source));
  }

  @override
  Future<void> removeAudioSourceAt(int index) async {
    removedIndexes.add(index);
    sources.removeAt(index);
  }

  @override
  Future<void> moveAudioSource(int from, int to) async {
    final p = sources.removeAt(from);
    sources.insert(to, p);
  }

  @override
  Future<void> setAudioSources(
    List<AudioSource> list, {
    int? initialIndex,
    Duration initialPosition = Duration.zero,
  }) async {
    // Faithfully models just_audio 0.10.5: an EMPTY list is a no-op on the
    // native backend (load() early-returns on an empty playlist, sending no
    // message), so the previous sources and current index are left intact. A
    // non-empty list replaces the playlist and seeds the current index.
    if (list.isEmpty) return;
    stopCalled = false;
    sources
      ..clear()
      ..addAll(list.map(_path));
    setCurrentIndex(initialIndex ?? 0);
  }

  @override
  Future<void> seek(Duration position, {int? index}) async {
    seeks.add((position: position, index: index));
    if (index != null) setCurrentIndex(index);
  }

  @override
  Future<void> play() async {
    played = true;
  }

  @override
  Future<void> stop() async {
    // Models just_audio deactivating the native platform: playback halts and
    // the native sequence is torn down (a later non-empty setAudioSources/play
    // rebuilds it from the Dart playlist).
    stopCalled = true;
    played = false;
    sources.clear();
    setCurrentIndex(null);
  }

  @override
  Duration get position => Duration.zero;
}
