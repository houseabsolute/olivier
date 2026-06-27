import 'package:flutter/material.dart';
import 'package:olivier/audio/audio_handler.dart';
import 'package:olivier/widgets/search_field.dart';
import 'package:olivier/widgets/volume_control.dart';

/// The app-bar title content: search fills the center, volume on the right.
/// (Transport controls now live in the bottom now-playing bar.)
class TopControls extends StatelessWidget {
  const TopControls({super.key, required this.audioHandler});

  final OlivierAudioHandler audioHandler;

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(child: Center(child: SearchField())),
        SizedBox(width: 8),
        VolumeControl(),
      ],
    );
  }
}
