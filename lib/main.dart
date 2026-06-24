import 'dart:async' show runZonedGuarded;
import 'dart:io' show Directory, File, Platform;
import 'dart:ui' show PlatformDispatcher;

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
import 'package:olivier/src/rust/api/activity.dart';
import 'package:olivier/src/rust/api/queue.dart';
import 'package:olivier/src/rust/frb_generated.dart';
import 'package:olivier/state/error_reporter.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/volume.dart';
import 'package:olivier/theme.dart';
import 'package:path_provider/path_provider.dart';

late final OlivierAudioHandler audioHandler;
late final String dbPath;
late final QueueController queueController;
late final PlaybackController playbackController;

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
ErrorReporter? errorReporter;

/// Route Flutter framework + platform async errors to [reporter]. Exposed for
/// testing the routing contract.
void installErrorHandlers(ErrorReporter reporter) {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    reporter.report(details.exception, stack: details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    reporter.report(error, stack: stack);
    return true;
  };
}

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    JustAudioMediaKit.ensureInitialized(
      linux: true,
      windows: false,
      android: false,
      iOS: false,
      macOS: false,
    );
    await RustLib.init();

    // Compute DB path once for the entire app lifetime. Stored under the XDG
    // data dir (~/.local/share/olivier on Linux), migrating any DB from the old
    // documents-dir location on first run.
    dbPath = await _resolveDbPath();

    final reporter = ErrorReporter(
      messengerKey: scaffoldMessengerKey,
      logActivity: (category, detail) =>
          logActivity(dbPath: dbPath, category: category, detail: detail),
    );
    errorReporter = reporter;
    installErrorHandlers(reporter);

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
          errorReporterProvider.overrideWithValue(reporter),
        ],
        child: Consumer(
          builder: (context, ref, _) => OlivierApp(
            onVolumeUp: () =>
                ref.read(volumeProvider.notifier).nudge(volumeStep),
            onVolumeDown: () =>
                ref.read(volumeProvider.notifier).nudge(-volumeStep),
          ),
        ),
      ),
    );
  }, (error, stack) {
    // Uncaught async errors (incl. the unawaited streaming-FFI return port).
    errorReporter?.report(error, stack: stack);
  });
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

/// Per-keypress steps for the transport/volume keyboard shortcuts.
const volumeStep = 0.05;
const seekStep = Duration(seconds: 10);

class OlivierApp extends StatelessWidget {
  const OlivierApp({
    super.key,
    this.onQuit,
    this.onTogglePlayPause,
    this.onNextTrack,
    this.onPreviousTrack,
    this.onSeekForward,
    this.onSeekBackward,
    this.onVolumeUp,
    this.onVolumeDown,
    this.home,
  });

  /// Injectable so the Ctrl-Q binding is testable; defaults to quitting.
  final VoidCallback? onQuit;

  /// Injectable so the space-bar play/pause binding is testable; defaults to
  /// toggling the global audio handler.
  final VoidCallback? onTogglePlayPause;

  /// Injectable transport actions (Ctrl/Cmd+←/→, Shift+←/→). Default to the
  /// global audio handler; overridden in tests.
  final VoidCallback? onNextTrack;
  final VoidCallback? onPreviousTrack;
  final VoidCallback? onSeekForward;
  final VoidCallback? onSeekBackward;

  /// Injectable volume actions (Ctrl/Cmd+↑/↓). No global default — volume needs
  /// the provider, which this StatelessWidget can't read, so they are injected
  /// in main() under the ProviderScope (null ⇒ the chord is ignored).
  final VoidCallback? onVolumeUp;
  final VoidCallback? onVolumeDown;

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
          // Media shortcuts fire on key-down only (no auto-repeat on hold) and
          // yield entirely to a focused text field, so typing — including
          // in-field Ctrl+←/→ word-jump and Shift+←/→ selection — is preserved.
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (textInputHasFocus()) return KeyEventResult.ignored;

          final key = event.logicalKey;
          final kb = HardwareKeyboard.instance;
          final mod = kb.isControlPressed || kb.isMetaPressed; // Ctrl or Cmd
          final shift = kb.isShiftPressed;

          if (key == LogicalKeyboardKey.space && !mod && !shift) {
            (onTogglePlayPause ?? () => audioHandler.togglePlayPause())();
            return KeyEventResult.handled;
          }

          if (mod && !shift) {
            if (key == LogicalKeyboardKey.arrowRight) {
              (onNextTrack ?? () => audioHandler.skipToNext())();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowLeft) {
              (onPreviousTrack ?? () => audioHandler.skipToPrevious())();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowUp && onVolumeUp != null) {
              onVolumeUp!();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowDown && onVolumeDown != null) {
              onVolumeDown!();
              return KeyEventResult.handled;
            }
          }

          if (shift && !mod) {
            if (key == LogicalKeyboardKey.arrowRight) {
              (onSeekForward ?? () => audioHandler.seekBy(seekStep))();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowLeft) {
              (onSeekBackward ?? () => audioHandler.seekBy(-seekStep))();
              return KeyEventResult.handled;
            }
          }

          return KeyEventResult.ignored;
        },
        child: MaterialApp(
          title: 'Olivier',
          theme: olivierTheme(),
          scaffoldMessengerKey: scaffoldMessengerKey,
          home: home ?? const BrowserPage(),
        ),
      ),
    );
  }
}

/// Whether a text-editing widget currently holds focus, so the global media
/// shortcuts yield to typing. On a real device a modifier/space key event still
/// bubbles to the root [Focus] while a field is focused (the character is
/// inserted via the text-input system), so this gate is what suppresses it; in
/// the widget-test harness the focused [EditableText] consumes the event first,
/// so the gate is exercised directly by its own unit test rather than through a
/// shortcut. Exposed for that test.
@visibleForTesting
bool textInputHasFocus() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  return ctx.widget is EditableText ||
      ctx.findAncestorStateOfType<EditableTextState>() != null;
}
