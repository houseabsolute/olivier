import 'package:flutter/material.dart';
import 'package:olivier/src/rust/catalog/schema.dart';

/// Map a dialog field to a stored override value: unchanged from the enriched
/// value -> null (automatic); cleared a non-empty enriched value -> '' (suppress
/// — hide the wrong auto value); otherwise the trimmed text (override).
String? overrideTitleValue(String field, String? enriched) {
  final v = field.trim();
  if (v == (enriched ?? '')) return null;
  if (v.isEmpty) return '';
  return v;
}

/// Loads the current reading/translation (enriched + override) for a title, shows
/// the dialog, and on Save persists via [onSubmit] and runs [onSaved] (refresh).
Future<void> showTitleOverrideDialog(
  BuildContext context, {
  required String label,
  required TitleOverride current,
  required Future<void> Function(String? translit, String? translate) onSubmit,
  required void Function() onSaved,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => TitleOverrideDialog(
      label: label,
      current: current,
      onSubmit: (t, tr) async {
        await onSubmit(t, tr);
        onSaved();
      },
    ),
  );
}

/// Edit dialog for one track's/release's reading + translation overrides. Pure:
/// the parent supplies the loaded [current] override and an [onSubmit] that
/// persists the result, so it can be pumped directly in tests.
class TitleOverrideDialog extends StatefulWidget {
  const TitleOverrideDialog({
    super.key,
    required this.label,
    required this.current,
    required this.onSubmit,
  });

  final String label;
  final TitleOverride current;
  final Future<void> Function(String? translit, String? translate) onSubmit;

  @override
  State<TitleOverrideDialog> createState() => _TitleOverrideDialogState();
}

class _TitleOverrideDialogState extends State<TitleOverrideDialog> {
  late final TextEditingController _reading = TextEditingController(
    text: widget.current.translitOverride ?? widget.current.translit ?? '',
  );
  late final TextEditingController _translation = TextEditingController(
    text: widget.current.translateOverride ?? widget.current.translate ?? '',
  );

  @override
  void dispose() {
    _reading.dispose();
    _translation.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final t = overrideTitleValue(_reading.text, widget.current.translit);
    final tr = overrideTitleValue(_translation.text, widget.current.translate);
    await widget.onSubmit(t, tr);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Set reading — ${widget.label}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _reading,
              decoration: InputDecoration(
                labelText: 'Reading',
                helperText: 'MusicBrainz: ${widget.current.translit ?? '—'}',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _translation,
              decoration: InputDecoration(
                labelText: 'Translation',
                helperText: 'MusicBrainz: ${widget.current.translate ?? '—'}',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
