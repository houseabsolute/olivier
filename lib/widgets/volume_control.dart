import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/state/volume.dart';

/// A volume icon plus a compact slider bound to [volumeProvider].
/// `onChanged` gives live feedback (apply, no save); `onChangeEnd` persists.
class VolumeControl extends ConsumerWidget {
  const VolumeControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vol = ref.watch(volumeProvider).value ?? defaultVolume;
    final icon = vol <= 0
        ? Icons.volume_off
        : vol < 0.5
            ? Icons.volume_down
            : Icons.volume_up;
    final notifier = ref.read(volumeProvider.notifier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20),
        SizedBox(
          width: 120,
          child: Slider(
            value: vol,
            onChanged: (v) => notifier.setVolume(v),
            onChangeEnd: (v) => notifier.setVolume(v, persist: true),
          ),
        ),
      ],
    );
  }
}
