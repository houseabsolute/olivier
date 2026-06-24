import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/state/error_reporter.dart';

void main() {
  testWidgets('report shows a snackbar and appends to the activity log',
      (tester) async {
    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    final logged = <(String, String)>[];
    final reporter = ErrorReporter(
      messengerKey: messengerKey,
      logActivity: (cat, detail) async => logged.add((cat, detail)),
    );

    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: messengerKey,
      home: const Scaffold(body: SizedBox.shrink()),
    ));

    reporter.report(Exception('kaboom'));
    await tester.pump();

    expect(find.textContaining('kaboom'), findsOneWidget);
    expect(logged.single.$1, 'ERROR');
    expect(logged.single.$2, contains('kaboom'));
  });

  testWidgets('identical errors are de-duped within the window',
      (tester) async {
    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    var calls = 0;
    final reporter = ErrorReporter(
      messengerKey: messengerKey,
      logActivity: (cat, detail) async => calls++,
    );
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: messengerKey,
      home: const Scaffold(body: SizedBox.shrink()),
    ));
    reporter.report(Exception('same'));
    reporter.report(Exception('same'));
    await tester.pump();
    expect(calls, 1,
        reason: 'second identical report within the window is suppressed');
  });
}
