import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Central error sink: shows a transient snackbar (via a global messenger key,
/// so it works from outside any widget context) and appends an ERROR line to
/// the activity log. Fed by the global guard in main() and usable from anywhere.
class ErrorReporter {
  ErrorReporter({required this.messengerKey, required this.logActivity});

  final GlobalKey<ScaffoldMessengerState> messengerKey;
  final Future<void> Function(String category, String detail) logActivity;

  String? _lastMessage;
  DateTime? _lastAt;

  void report(Object error, {StackTrace? stack, String? context}) {
    final message = context == null ? '$error' : '$context: $error';

    // De-dup: suppress an identical message seen within the last 3 seconds so a
    // repeating failure doesn't flood the user.
    final now = DateTime.now();
    if (_lastMessage == message &&
        _lastAt != null &&
        now.difference(_lastAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastMessage = message;
    _lastAt = now;

    // Best-effort persistent record; never let logging throw.
    logActivity('ERROR', message).catchError((_) {});

    messengerKey.currentState
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
        behavior: SnackBarBehavior.floating,
      ));
  }
}

/// Overridden in main()'s ProviderScope to the app-wide instance so widgets can
/// report errors too.
final errorReporterProvider = Provider<ErrorReporter>((ref) =>
    throw UnimplementedError('errorReporterProvider must be overridden'));
