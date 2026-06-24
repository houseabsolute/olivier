import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/main.dart' show audioHandler;
import 'package:olivier/state/providers.dart';

const volumeKey = 'volume';
const defaultVolume = 1.0;

/// Parse a stored volume string; clamp to [0,1]; [defaultVolume] on bad/missing
/// input. ([num.clamp] returns `num`, so `.toDouble()` keeps the return typed.)
double parseVolume(String? s) {
  final v = s == null ? null : double.tryParse(s);
  if (v == null) return defaultVolume;
  return v.clamp(0.0, 1.0).toDouble();
}

/// Applies a volume to the player. A seam so [VolumeNotifier] is testable
/// without the live audio handler; defaults to the global handler.
typedef SetVolumeFn = Future<void> Function(double v);
final setVolumeFnProvider =
    Provider<SetVolumeFn>((ref) => audioHandler.setVolume);

class VolumeNotifier extends AsyncNotifier<double> {
  @override
  Future<double> build() async {
    final v = parseVolume(await ref.read(getSettingFnProvider)(volumeKey));
    await ref.read(setVolumeFnProvider)(v); // apply the saved level on startup
    return v;
  }

  /// Apply a new volume immediately; persist only when [persist] (on slider
  /// release), so dragging doesn't spam the settings write.
  Future<void> setVolume(double v, {bool persist = false}) async {
    final clamped = v.clamp(0.0, 1.0).toDouble();
    state = AsyncData(clamped);
    await ref.read(setVolumeFnProvider)(clamped);
    if (persist) {
      await ref.read(setSettingFnProvider)(volumeKey, clamped.toString());
    }
  }

  /// Nudge the volume by [delta] (keyboard Up/Down). Delegates to [setVolume]
  /// (which clamps to [0,1]) and persists so the level survives a restart.
  Future<void> nudge(double delta) =>
      setVolume((state.value ?? defaultVolume) + delta, persist: true);
}

final volumeProvider =
    AsyncNotifierProvider<VolumeNotifier, double>(VolumeNotifier.new);
