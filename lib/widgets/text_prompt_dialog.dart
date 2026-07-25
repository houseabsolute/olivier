import 'package:flutter/material.dart';

/// A one-field prompt that owns its [TextEditingController].
///
/// The controller has to belong to a widget, not the caller: disposing it right
/// after `showDialog` resolves tears it down while the dialog's exit transition
/// is still running and its `TextField` is still listening, which trips
/// `ChangeNotifier` "used after being disposed". A [State] disposes only once
/// the route is actually gone.
class TextPromptDialog extends StatefulWidget {
  const TextPromptDialog({
    super.key,
    required this.title,
    this.initial = '',
    this.hintText,
    this.helperText,
    this.confirmLabel = 'OK',
    this.subtitle,
  });

  final String title;
  final String initial;
  final String? hintText;
  final String? helperText;
  final String confirmLabel;

  /// Optional line above the field, for context the title can't carry.
  final String? subtitle;

  @override
  State<TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<TextPromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.subtitle != null) ...[
            Text(widget.subtitle!,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
          ],
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: widget.hintText,
              helperText: widget.helperText,
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Show a [TextPromptDialog] and return what was entered, or null if cancelled.
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  String initial = '',
  String? hintText,
  String? helperText,
  String confirmLabel = 'OK',
  String? subtitle,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => TextPromptDialog(
      title: title,
      initial: initial,
      hintText: hintText,
      helperText: helperText,
      confirmLabel: confirmLabel,
      subtitle: subtitle,
    ),
  );
}
