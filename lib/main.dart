import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_mpris/audio_service_mpris.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:olivier/audio/audio_handler.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/api/queue.dart';
import 'package:olivier/src/rust/api/simple.dart';
import 'package:olivier/src/rust/frb_generated.dart';
import 'package:path_provider/path_provider.dart';

late final OlivierAudioHandler audioHandler;
late final String dbPath;

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

  // Compute DB path once for the entire app lifetime.
  final docsDir = await getApplicationDocumentsDirectory();
  dbPath = '${docsDir.path}/olivier.db';

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
  late final QueueController _queue =
      QueueController(audioHandler.player, dbPath: dbPath);
  bool _shuffleOn = false;
  bool _restored = false;
  int _restoredCount = 0;

  @override
  void initState() {
    super.initState();
    _tryRestoreQueue();
  }

  Future<void> _tryRestoreQueue() async {
    final snap = await loadQueue(dbPath: dbPath);
    if (snap != null && snap.paths.isNotEmpty) {
      await _queue.restoreFromSnapshot(snap);
      setState(() {
        _restored = true;
        _restoredCount = snap.paths.length;
        _shuffleOn = snap.shuffle;
      });
    }
  }

  // --- spike: single-track play (Task 9) ---
  Future<void> _playTest() async {
    // Plays a bundled fixture to confirm the libmpv engine starts. Absolute path
    // because `flutter run` launches with CWD=/tmp. For an AUDIBLE / per-codec test,
    // point this at real library files (the fixtures are 1 s of silence).
    await audioHandler.player.setFilePath(
        '/home/autarch/mnt/music/Hitsujibungaku/12_hugs__like_butterflies_/01-Hug_m4a.mp3');
    await audioHandler.play();
  }

  // --- spike: 3-track queue + shuffle (Task 10) ---
  // Absolute paths: `flutter run` launches the app with CWD=/tmp, so relative
  // fixture paths don't resolve. (Phase 1 plays real catalog paths instead.)
  static const _fixtureDir =
      '/home/autarch/projects/olivier/rust/tests/fixtures';
  static const _fixtureQueue = [
    '$_fixtureDir/sample.flac',
    '$_fixtureDir/sample.mp3',
    '$_fixtureDir/sample.opus',
  ];

  Future<void> _queueAndPlay() async {
    await _queue.setQueue(_fixtureQueue);
    setState(() {
      _restored = false;
      _restoredCount = 0;
    });
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
            const SizedBox(height: 8),

            // Task 12 — persisted-queue status
            Text(
              _restored
                  ? 'queue: $_restoredCount tracks (restored)'
                  : 'queue: ${_queue.orderedPaths.length} tracks',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
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
