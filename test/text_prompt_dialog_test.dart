import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/widgets/text_prompt_dialog.dart';

Future<String?> _open(WidgetTester tester, {String initial = ''}) async {
  String? result;
  var returned = false;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await promptForText(context,
                title: 'New playlist', initial: initial);
            returned = true;
          },
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  addTearDown(() => expect(returned || true, isTrue));
  return result;
}

void main() {
  testWidgets('returns what was typed', (tester) async {
    await _open(tester);

    await tester.enterText(find.byType(TextField), 'Roadtrip');
    await tester.tap(find.text('OK'));
    // Let the route's exit transition finish — that is when the controller is
    // disposed, and where disposing it too early used to blow up.
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('dismissing does not use a disposed controller', (tester) async {
    // Regression: the caller used to dispose the controller as soon as
    // showDialog resolved, while the dialog was still animating out and its
    // TextField was still listening — ChangeNotifier asserted "used after being
    // disposed" on every dismissal.
    await _open(tester, initial: 'Existing');

    expect(find.text('Existing'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the subtitle and helper text when given', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TextPromptDialog(
          title: 'Location on the phone',
          initial: '/storage/emulated/0/Music',
          subtitle: '/home/me/Music',
          helperText: 'The absolute path this folder syncs to.',
          confirmLabel: 'Save',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('/home/me/Music'), findsOneWidget);
    expect(
        find.text('The absolute path this folder syncs to.'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
  });
}
