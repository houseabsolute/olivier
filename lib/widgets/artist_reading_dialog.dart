import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

/// The value to persist for one override dimension: the trimmed field text,
/// unless it is empty or matches the MusicBrainz value, in which case `null`
/// (no override — fall back to MusicBrainz).
String? overrideValue(String field, String? mbValue) {
  final v = field.trim();
  if (v.isEmpty || v == (mbValue ?? '')) return null;
  return v;
}

/// Loads the artist's raw reading/sort, shows [ArtistReadingDialog], and on Save
/// persists the override and refreshes the artist list.
Future<void> showArtistReadingDialog(
  BuildContext context,
  WidgetRef ref,
  String mbid,
) async {
  final reading = await ref.read(artistReadingFnProvider)(mbid);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => ArtistReadingDialog(
      reading: reading,
      onSubmit: (r, s) async {
        await ref.read(setArtistReadingOverrideFnProvider)(mbid, r, s);
        ref.invalidate(artistsProvider);
      },
    ),
  );
}

/// Edit dialog for one artist's reading + sort overrides. Pure: the parent
/// supplies the loaded [reading] and an [onSubmit] that persists the result, so
/// it can be pumped directly in tests.
class ArtistReadingDialog extends StatefulWidget {
  const ArtistReadingDialog({
    super.key,
    required this.reading,
    required this.onSubmit,
  });

  final ArtistReading reading;
  final Future<void> Function(String? reading, String? sort) onSubmit;

  @override
  State<ArtistReadingDialog> createState() => _ArtistReadingDialogState();
}

class _ArtistReadingDialogState extends State<ArtistReadingDialog> {
  late final TextEditingController _reading = TextEditingController(
    text: widget.reading.transliterationOverride ??
        widget.reading.mbTransliteration ??
        '',
  );
  late final TextEditingController _sort = TextEditingController(
    text: widget.reading.sortNameOverride ?? widget.reading.mbSortName,
  );

  @override
  void dispose() {
    _reading.dispose();
    _sort.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final r = overrideValue(_reading.text, widget.reading.mbTransliteration);
    final s = overrideValue(_sort.text, widget.reading.mbSortName);
    await widget.onSubmit(r, s);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final original = widget.reading.nameOriginal ?? widget.reading.name;
    return AlertDialog(
      title: Text('Set reading — $original'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _reading,
              decoration: InputDecoration(
                labelText: 'Reading',
                helperText:
                    'MusicBrainz: ${widget.reading.mbTransliteration ?? '—'}',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _sort,
              decoration: InputDecoration(
                labelText: 'Sort as',
                helperText: 'MusicBrainz: ${widget.reading.mbSortName}',
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
