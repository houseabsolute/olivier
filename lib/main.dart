import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_mpris/audio_service_mpris.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:olivier/audio/audio_handler.dart';
import 'package:olivier/catalog/browser_page.dart';
import 'package:olivier/src/rust/api/queue.dart';
import 'package:olivier/src/rust/frb_generated.dart';
import 'package:olivier/state/providers.dart';
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

  // Restore persisted queue from the last session if present.
  final snap = await loadQueue(dbPath: dbPath);
  if (snap != null && snap.paths.isNotEmpty) {
    // Task 9 will wire this into the audio handler; stash it for now.
  }

  runApp(
    ProviderScope(
      overrides: [
        dbPathProvider.overrideWithValue(dbPath),
      ],
      child: const OlivierApp(),
    ),
  );
}

class OlivierApp extends StatelessWidget {
  const OlivierApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Olivier',
      home: BrowserPage(),
    );
  }
}
