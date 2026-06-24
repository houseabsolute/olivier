import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/main.dart';

// Directly exercises the focus gate that suppresses the media shortcuts while a
// text field is focused. The widget-test harness lets a focused EditableText
// consume modifier/arrow key events before they reach the root handler, so the
// gate cannot be observed through a shortcut press — this unit test verifies its
// logic instead. (On a real device the gate is what suppresses Space, whose
// event does bubble while editing.)
void main() {
  testWidgets('textInputHasFocus is true only when an editable text is focused',
      (tester) async {
    final fieldFocus = FocusNode(debugLabel: 'field');
    final plainFocus = FocusNode(debugLabel: 'plain');
    addTearDown(fieldFocus.dispose);
    addTearDown(plainFocus.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            TextField(focusNode: fieldFocus),
            Focus(focusNode: plainFocus, child: const Text('not a field')),
          ],
        ),
      ),
    ));

    // Nothing focused yet (or the framework's default) → not a text field.
    plainFocus.requestFocus();
    await tester.pump();
    expect(textInputHasFocus(), isFalse,
        reason: 'a non-text focus owner must not count as text input');

    // The text field holds focus → gate is active.
    fieldFocus.requestFocus();
    await tester.pump();
    expect(textInputHasFocus(), isTrue);

    // Move focus away again → gate releases.
    plainFocus.requestFocus();
    await tester.pump();
    expect(textInputHasFocus(), isFalse);
  });
}
