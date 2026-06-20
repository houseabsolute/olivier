import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:url_launcher/url_launcher.dart';

final _mbidUuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// The musicbrainz.org URL for an entity, or null when [mbid] is not a real
/// MBID (a synth key like `synth:aa:…`, or null/empty). [entityType] is one of
/// `release`, `artist`, `recording`.
String? mbUrl(String entityType, String? mbid) {
  if (mbid == null || !_mbidUuid.hasMatch(mbid)) return null;
  return 'https://musicbrainz.org/$entityType/$mbid';
}

/// Opens a MusicBrainz URL. Overridable in tests; defaults to the external
/// browser.
Future<void> Function(String url) launchMbUrl =
    (url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

/// A read-only, copy-pasteable info dialog: label/value rows where each value is
/// selectable text. The caller passes only non-empty fields. The optional third
/// element of each tuple is a URL to open when the value is tapped.
Future<void> showInfoDialog(
  BuildContext context, {
  required String title,
  required List<(String, String, String?)> fields,
  Widget? header,
}) {
  final recognizers = <String, TapGestureRecognizer>{};
  for (final (_, _, url) in fields) {
    if (url != null && !recognizers.containsKey(url)) {
      recognizers[url] = TapGestureRecognizer()..onTap = () => launchMbUrl(url);
    }
  }
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
              if (header != null) ...[
                Center(child: header),
                const SizedBox(height: 12),
              ],
              for (final (label, value, url) in fields)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: Theme.of(context).textTheme.labelSmall),
                      if (url == null)
                        SelectableText(value)
                      else
                        SelectableText.rich(TextSpan(
                          text: value,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            decoration: TextDecoration.underline,
                          ),
                          recognizer: recognizers[url],
                        )),
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
  ).whenComplete(() {
    for (final r in recognizers.values) {
      r.dispose();
    }
  });
}

String _fmtLen(BigInt? ms) {
  if (ms == null) return '';
  final s = (ms ~/ BigInt.from(1000)).toInt();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String _fmtEpoch(int? secs) {
  if (secs == null || secs == 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(secs * 1000); // local time
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

void _add(List<(String, String, String?)> out, String label, String? value,
    [String? url]) {
  final v = (value ?? '').trim();
  if (v.isNotEmpty) out.add((label, v, url));
}

/// Non-empty info fields for a track, in display order.
List<(String, String, String?)> trackInfoFields(Track t) {
  final out = <(String, String, String?)>[];
  _add(out, 'Title', t.title);
  _add(out, 'Reading', t.titleTranslit);
  _add(out, 'Translation', t.titleTranslate);
  _add(out, 'Album artist', t.albumArtistOriginal ?? t.albumArtist);
  _add(out, 'Album artist reading', t.albumArtistReading);
  _add(out, 'Recording MBID', t.recordingMbid,
      mbUrl('recording', t.recordingMbid));
  _add(out, 'Album artist MBID', t.albumArtistMbid,
      mbUrl('artist', t.albumArtistMbid));
  _add(out, 'Disc / Track', '${t.disc} / ${t.position}');
  _add(out, 'Length', _fmtLen(t.lengthMs));
  _add(out, 'Last played', _fmtEpoch(t.lastPlayed));
  _add(out, 'Added at', _fmtEpoch(t.addedAt));
  _add(out, 'Track id', t.id.toString());
  return out;
}

/// Non-empty info fields for a queued track, in display order.
List<(String, String, String?)> queueTrackInfoFields(QueueTrack t) {
  final out = <(String, String, String?)>[];
  _add(out, 'Title', t.title);
  _add(out, 'Reading', t.titleTranslit);
  _add(out, 'Translation', t.titleTranslate);
  _add(out, 'Album artist', t.albumArtistOriginal ?? t.albumArtist);
  _add(out, 'Album artist reading', t.albumArtistReading);
  _add(out, 'Recording MBID', t.recordingMbid,
      mbUrl('recording', t.recordingMbid));
  _add(out, 'Album artist MBID', t.albumArtistMbid,
      mbUrl('artist', t.albumArtistMbid));
  _add(out, 'Album', t.album);
  _add(out, 'Length', _fmtLen(t.lengthMs));
  _add(out, 'Date added', _fmtEpoch(t.addedAt));
  _add(out, 'Last played', _fmtEpoch(t.lastPlayed));
  _add(out, 'Path', t.path);
  return out;
}

/// Non-empty info fields for an album, in display order.
List<(String, String, String?)> albumInfoFields(Album a) {
  final out = <(String, String, String?)>[];
  _add(out, 'Title', a.title);
  _add(out, 'Reading', a.titleTranslit);
  _add(out, 'Translation', a.titleTranslate);
  _add(out, 'Album artist', a.albumArtistOriginal ?? a.albumArtist);
  _add(out, 'Album artist reading', a.albumArtistReading);
  _add(out, 'Original year', a.originalYear);
  _add(out, 'Reissue year', a.reissueYear);
  _add(out, 'Release MBID', a.releaseMbid, mbUrl('release', a.releaseMbid));
  _add(out, 'Album artist MBID', a.albumArtistMbid,
      mbUrl('artist', a.albumArtistMbid));
  _add(out, 'Date added', _fmtEpoch(a.addedAt));
  return out;
}
