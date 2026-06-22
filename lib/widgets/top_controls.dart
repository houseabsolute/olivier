import 'package:flutter/material.dart';
import 'package:olivier/audio/audio_handler.dart';
import 'package:olivier/widgets/search_field.dart';
import 'package:olivier/widgets/transport_controls.dart';
import 'package:olivier/widgets/volume_control.dart';

/// The app-bar title content: transport on the left, search in the center,
/// volume on the right.
class TopControls extends StatelessWidget {
  const TopControls({super.key, required this.audioHandler});

  final OlivierAudioHandler audioHandler;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        TransportControls(audioHandler: audioHandler),
        const SizedBox(width: 8),
        const Expanded(child: Center(child: SearchField())),
        const SizedBox(width: 8),
        const VolumeControl(),
      ],
    );
  }
}
