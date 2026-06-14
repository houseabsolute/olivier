import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_mpris/audio_service_mpris.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:olivier/audio/audio_handler.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/api/simple.dart';
import 'package:olivier/src/rust/frb_generated.dart';

late final OlivierAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  JustAudioMediaKit.ensureInitialized(
    linux: true,
    windows: false,
    android: false,
    iOS: false,
    macOS: false,
  );
  await RustLib.init();
  if (Platform.isLinux) {
    AudioServiceMpris.init(
      dBusName: 'OlivierMusicPlayer',
      identity: 'Olivier',
      // Without these, MPRIS advertises no capabilities and playerctl / desktop
      // controls are inert — which would defeat the point of this spike.
      canControl: true,
      canPlay: true,
      canPause: true,
      canGoNext: true,
      canGoPrevious: true,
    );
  }
  audioHandler = await AudioService.init(
    builder: () => OlivierAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'org.urth.olivier.channel.audio',
      androidNotificationChannelName: 'Music playback',
      androidNotificationOngoing: true,
    ),
  );
  runApp(const OlivierApp());
}

class OlivierApp extends StatelessWidget {
  const OlivierApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Olivier',
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final QueueController _queue = QueueController(audioHandler.player);
  bool _shuffleOn = false;

  // --- spike: single-track play (Task 9) ---
  Future<void> _playTest() async {
    // Plays a bundled fixture to confirm the libmpv engine starts.
    // For audible / per-codec testing a human will point this at real library files.
    await audioHandler.player.setFilePath('rust/tests/fixtures/sample.flac');
    await audioHandler.play();
  }

  // --- spike: 3-track queue + shuffle (Task 10) ---
  static const _fixtureQueue = [
    'rust/tests/fixtures/sample.flac',
    'rust/tests/fixtures/sample.mp3',
    'rust/tests/fixtures/sample.opus',
  ];

  Future<void> _queueAndPlay() async {
    await _queue.setQueue(_fixtureQueue);
    await audioHandler.play();
  }

  Future<void> _toggleShuffle(bool on) async {
    setState(() => _shuffleOn = on);
    await _queue.setShuffle(on);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Olivier')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(olivierVersion()),
            const SizedBox(height: 16),

            // Task 9 — single-track smoke test
            ElevatedButton(
              onPressed: _playTest,
              child: const Text('Play'),
            ),
            const SizedBox(height: 8),

            // Task 10 — queue + shuffle exerciser
            ElevatedButton(
              onPressed: _queueAndPlay,
              child: const Text('Queue 3'),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Shuffle'),
                Switch(
                  value: _shuffleOn,
                  onChanged: _toggleShuffle,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
