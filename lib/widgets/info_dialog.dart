import 'package:flutter/material.dart';
import 'package:olivier/src/rust/catalog/schema.dart';

/// A read-only, copy-pasteable info dialog: label/value rows where each value is
/// selectable text. The caller passes only non-empty fields.
Future<void> showInfoDialog(
  BuildContext context, {
  required String title,
  required List<(String, String)> fields,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (label, value) in fields)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: Theme.of(context).textTheme.labelSmall),
                      SelectableText(value),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

String _fmtLen(BigInt? ms) {
  if (ms == null) return '';
  final s = (ms ~/ BigInt.from(1000)).toInt();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

void _add(List<(String, String)> out, String label, String? value) {
  final v = (value ?? '').trim();
  if (v.isNotEmpty) out.add((label, v));
}

/// Non-empty info fields for a track, in display order.
List<(String, String)> trackInfoFields(Track t) {
  final out = <(String, String)>[];
  _add(out, 'Title', t.title);
  _add(out, 'Reading', t.titleTranslit);
  _add(out, 'Translation', t.titleTranslate);
  _add(out, 'Artist', t.artist);
  _add(out, 'Disc / Track', '${t.disc} / ${t.position}');
  _add(out, 'Length', _fmtLen(t.lengthMs));
  _add(out, 'Track id', t.id.toString());
  return out;
}

/// Non-empty info fields for an album, in display order.
List<(String, String)> albumInfoFields(Album a) {
  final out = <(String, String)>[];
  _add(out, 'Title', a.title);
  _add(out, 'Reading', a.titleTranslit);
  _add(out, 'Translation', a.titleTranslate);
  _add(out, 'Album artist', a.albumArtist);
  _add(out, 'Original year', a.originalYear);
  _add(out, 'Reissue year', a.reissueYear);
  _add(out, 'Release MBID', a.releaseMbid);
  return out;
}
