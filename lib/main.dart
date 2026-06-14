import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/src/rust/api/simple.dart';
import 'package:olivier/src/rust/frb_generated.dart';

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
  final _player = AudioPlayer();
  late final QueueController _queue = QueueController(_player);
  bool _shuffleOn = false;

  // --- spike: single-track play (Task 9) ---
  Future<void> _playTest() async {
    // Plays a bundled fixture to confirm the libmpv engine starts.
    // For audible / per-codec testing a human will point this at real library files.
    await _player.setFilePath('rust/tests/fixtures/sample.flac');
    await _player.play();
  }

  // --- spike: 3-track queue + shuffle (Task 10) ---
  static const _fixtureQueue = [
    'rust/tests/fixtures/sample.flac',
    'rust/tests/fixtures/sample.mp3',
    'rust/tests/fixtures/sample.opus',
  ];

  Future<void> _queueAndPlay() async {
    await _queue.setQueue(_fixtureQueue);
    await _player.play();
  }

  Future<void> _toggleShuffle(bool on) async {
    setState(() => _shuffleOn = on);
    await _queue.setShuffle(on);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
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
