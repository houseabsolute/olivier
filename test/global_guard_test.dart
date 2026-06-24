import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/main.dart' show installErrorHandlers;
import 'package:olivier/state/error_reporter.dart';

void main() {
  // ErrorReporter.report() reaches through the global ScaffoldMessenger key,
  // which touches WidgetsBinding.instance; a plain test() needs the binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('installErrorHandlers routes FlutterError.onError to the reporter', () {
    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    final logged = <String>[];
    final reporter = ErrorReporter(
      messengerKey: messengerKey,
      logActivity: (cat, detail) async => logged.add(detail),
    );
    final previous = FlutterError.onError;
    installErrorHandlers(reporter);
    addTearDown(() => FlutterError.onError = previous);

    FlutterError
        .onError!(FlutterErrorDetails(exception: Exception('build boom')));
    expect(logged.single, contains('build boom'));
  });
}
