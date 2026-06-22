import 'dart:io' show Directory, File, Platform;

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_mpris/audio_service_mpris.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:olivier/audio/audio_handler.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/audio/queue_controller.dart';
import 'package:olivier/catalog/browser_page.dart';
import 'package:olivier/src/rust/api/queue.dart';
import 'package:olivier/src/rust/frb_generated.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/theme.dart';
import 'package:path_provider/path_provider.dart';

late final OlivierAudioHandler audioHandler;
late final String dbPath;
late final QueueController queueController;
late final PlaybackController playbackController;

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

  // Compute DB path once for the entire app lifetime. Stored under the XDG data
  // dir (~/.local/share/olivier on Linux), migrating any DB from the old
  // documents-dir location on first run.
  dbPath = await _resolveDbPath();

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

  queueController = QueueController(audioHandler.player, dbPath: dbPath);
  playbackController = PlaybackController(
    audioHandler: audioHandler,
    queueController: queueController,
    dbPath: dbPath,
  );

  // Restore persisted queue from the last session if present.
  final snap = await loadQueue(dbPath: dbPath);
  if (snap != null && snap.paths.isNotEmpty) {
    await queueController.restoreFromSnapshot(snap);
    await playbackController.restoreNowPlaying();
  }

  runApp(
    ProviderScope(
      overrides: [
        dbPathProvider.overrideWithValue(dbPath),
        playbackControllerProvider.overrideWithValue(playbackController),
      ],
      child: const OlivierApp(),
    ),
  );
}

/// Resolve the database path under the XDG data directory (`$XDG_DATA_HOME`,
/// default `~/.local/share`) in an `olivier` subdir, creating the directory and
/// migrating any DB from the previous (documents-dir) location.
Future<String> _resolveDbPath() async {
  final String dir;
  if (Platform.isLinux) {
    final xdg = Platform.environment['XDG_DATA_HOME'];
    final home = Platform.environment['HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      dir = '$xdg/olivier';
    } else if (home != null && home.isNotEmpty) {
      dir = '$home/.local/share/olivier';
    } else {
      dir = (await getApplicationSupportDirectory()).path;
    }
  } else {
    // Android and others: the platform's app-support directory.
    dir = (await getApplicationSupportDirectory()).path;
  }
  await Directory(dir).create(recursive: true);
  final dbFile = '$dir/olivier.db';
  await _migrateLegacyDb(dbFile);
  return dbFile;
}

/// One-time move of the database (and its WAL log) from the old documents-dir
/// location into [newDbPath] when the new location has none yet, so an existing
/// catalog, roots, play stats, and queue survive the relocation.
Future<void> _migrateLegacyDb(String newDbPath) async {
  if (await File(newDbPath).exists()) return;
  final String oldDir;
  try {
    oldDir = (await getApplicationDocumentsDirectory()).path;
  } catch (_) {
    return;
  }
  final oldDbPath = '$oldDir/olivier.db';
  if (!await File(oldDbPath).exists()) return;

  // Move the WAL log first and the database itself last: the `newDbPath` exists
  // check above is the migration's commit point, so the .db must only arrive
  // once its WAL is already beside it (a crash mid-move just retries next run).
  for (final suffix in ['-wal', '']) {
    final src = File('$oldDbPath$suffix');
    if (!await src.exists()) continue;
    final dest = '$newDbPath$suffix';
    try {
      await src.rename(dest);
    } catch (_) {
      // Cross-filesystem move: copy to a temp sibling on the destination fs,
      // atomically rename it into place, then remove the source — so a crash can
      // never delete the source before the destination is complete.
      final tmp = '$dest.tmp';
      await src.copy(tmp);
      await File(tmp).rename(dest);
      await src.delete();
    }
  }

  // -shm is shared-memory scratch SQLite rebuilds on open; drop the stale one.
  final oldShm = File('$oldDbPath-shm');
  if (await oldShm.exists()) {
    try {
      await oldShm.delete();
    } catch (_) {}
  }
}

class OlivierApp extends StatelessWidget {
  const OlivierApp({
    super.key,
    this.onQuit,
    this.onTogglePlayPause,
    this.home,
  });

  /// Injectable so the Ctrl-Q binding is testable; defaults to quitting.
  final VoidCallback? onQuit;

  /// Injectable so the space-bar play/pause binding is testable; defaults to
  /// toggling the global audio handler.
  final VoidCallback? onTogglePlayPause;

  /// Injectable home widget so the app can be widget-tested without the full
  /// BrowserPage + Riverpod provider stack. Defaults to [BrowserPage].
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyQ, control: true):
            onQuit ?? () => SystemNavigator.pop(),
      },
      child: Focus(
        autofocus: true,
        // Space toggles play/pause like a media key, but only when no text
        // field is focused — otherwise typing a space would also toggle
        // playback. The space key event still bubbles up here while editing
        // (the character is inserted via the text-input system rather than
        // consumed as a key event), so we explicitly yield when a text field
        // holds focus.
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.space &&
              !_textInputHasFocus()) {
            (onTogglePlayPause ?? () => audioHandler.togglePlayPause())();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MaterialApp(
          title: 'Olivier',
          theme: olivierTheme(),
          home: home ?? const BrowserPage(),
        ),
      ),
    );
  }
}

/// Whether a text-editing widget currently holds focus, so global single-key
/// shortcuts (like space → play/pause) can yield to typing.
bool _textInputHasFocus() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  return ctx.widget is EditableText ||
      ctx.findAncestorStateOfType<EditableTextState>() != null;
}
