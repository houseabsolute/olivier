# Clickable MusicBrainz Links in Info Popups — Design

**Status:** approved, ready for implementation plan
**Date:** 2026-06-20

## Goal

In the track / album / queue Info popups, render each MusicBrainz ID as a clickable link that
opens the corresponding entity on musicbrainz.org, while keeping it selectable/copyable. Links
cover the release, the album-artist, and (for tracks) the recording.

## What's there today

The only MBID shown is `Release MBID` in the album popup (`info_dialog.dart`), as plain
`SelectableText`. Track/queue popups show no MBID; artists have no Info popup. `url_launcher` is
not a dependency. The `Album` DTO carries `release_mbid`; `Track`/`QueueTrack` carry no MBIDs and
the album-artist MBID is not on any DTO.

## Key constraint: synth keys are not real MBIDs

For untagged content the app uses synthetic keys (`synth:aa:…` album-artist, `synth:rel:…`
release, `synth:rg:…` release-group). A real MBID is a UUID. **Only real UUIDs may be linked** —
synth keys and nulls must not produce a musicbrainz.org URL (it would 404).

## Data model (Rust)

Add the MBIDs the links need, all `Option<String>` (optional in Dart → existing fixtures unchanged).
Column indices below are exact against the current queries.

### `Album` (`schema.rs`) + `albums_for_artist` (`query.rs`)

Add `album_artist_mbid: Option<String>`. The query already filters/joins on `r.album_artist_mbid`;
add it to the SELECT after `COALESCE(...)` (currently col 9):

```sql
                a.name_original,
                COALESCE(a.transliteration_override, a.transliteration),
                r.album_artist_mbid
         FROM release r
```

Closure (after `album_artist_reading: r.get(9)?,`): `album_artist_mbid: r.get(10)?,`.

(`Album.release_mbid` already exists — no query change for it.)

### `Track` (`schema.rs`) + `tracks_for_album` (`query.rs`)

Add `recording_mbid: Option<String>` and `album_artist_mbid: Option<String>`. The query already
joins `release r`. Add to the SELECT after `COALESCE(...)` (currently col 12):

```sql
                aa.name, aa.name_original,
                COALESCE(aa.transliteration_override, aa.transliteration),
                t.recording_mbid, r.album_artist_mbid
         FROM track t
```

Closure (after `album_artist_reading: r.get(12)?,`): `recording_mbid: r.get(13)?,
album_artist_mbid: r.get(14)?,`.

### `QueueTrack` (`schema.rs`) + `tracks_for_paths` (`query.rs`)

Add `recording_mbid: Option<String>` and `album_artist_mbid: Option<String>`. Add to the SELECT
after `COALESCE(...)` (currently col 11):

```sql
                aa.name, aa.name_original,
                COALESCE(aa.transliteration_override, aa.transliteration),
                t.recording_mbid, r.album_artist_mbid
         FROM file f JOIN track t ON t.id = f.track_id
```

Found closure (after `album_artist_reading: r.get(11)?,`): `recording_mbid: r.get(12)?,
album_artist_mbid: r.get(13)?,`. The catalog-miss **placeholder** sets both to `None`.

### Bridge

Regenerate (`mise exec -- flutter_rust_bridge_codegen generate`) and commit `lib/src/rust/**` +
`rust/src/frb_generated.rs`. Dart fields: `albumArtistMbid`, `recordingMbid`.

## Dependency

Add `url_launcher` (^6) to `pubspec.yaml` (`mise exec -- flutter pub add url_launcher`).

## Dart — `lib/widgets/info_dialog.dart`

### `mbUrl` helper (pure, testable)

```dart
final _mbidUuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// The musicbrainz.org URL for an entity, or null when [mbid] is not a real
/// MBID (a synth key like `synth:aa:…`, or null/empty). [entityType] is one of
/// `release`, `artist`, `recording`.
String? mbUrl(String entityType, String? mbid) {
  if (mbid == null || !_mbidUuid.hasMatch(mbid)) return null;
  return 'https://musicbrainz.org/$entityType/$mbid';
}
```

### Field model: add an optional URL

Change the field record from `(String, String)` to `(String label, String value, String? url)`.
`_add` gains an optional `url`:

```dart
void _add(List<(String, String, String?)> out, String label, String? value,
    [String? url]) {
  final v = (value ?? '').trim();
  if (v.isNotEmpty) out.add((label, v, url));
}
```

Existing `_add(out, label, value)` calls are unchanged (url defaults null). The builders' return
type and `showInfoDialog`'s `fields` param become `List<(String, String, String?)>`.

### Builders attach links

- `albumInfoFields`: `_add(out, 'Release MBID', a.releaseMbid, mbUrl('release', a.releaseMbid));`
  and add `_add(out, 'Album artist MBID', a.albumArtistMbid, mbUrl('artist', a.albumArtistMbid));`
- `trackInfoFields`: add `_add(out, 'Recording MBID', t.recordingMbid, mbUrl('recording', t.recordingMbid));`
  and `_add(out, 'Album artist MBID', t.albumArtistMbid, mbUrl('artist', t.albumArtistMbid));`
- `queueTrackInfoFields`: same two as `trackInfoFields`.

A non-empty synth MBID still shows as a plain (unlinked) text row; a null MBID is omitted by `_add`.

### Render: clickable + selectable links, leak-free

`showInfoDialog` pre-builds one `TapGestureRecognizer` per distinct link URL (so they are not
recreated on dialog rebuilds), uses them in the rows, and disposes them when the dialog closes via
`.whenComplete(...)` — no `StatefulWidget` needed:

```dart
Future<void> showInfoDialog(
  BuildContext context, {
  required String title,
  required List<(String, String, String?)> fields,
  Widget? header,
}) {
  final recognizers = <String, TapGestureRecognizer>{};
  for (final (_, _, url) in fields) {
    if (url != null && !recognizers.containsKey(url)) {
      recognizers[url] = TapGestureRecognizer()
        ..onTap = () =>
            launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
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
```

Requires imports `package:flutter/gestures.dart` (TapGestureRecognizer) and
`package:url_launcher/url_launcher.dart` (launchUrl).

## Testing

### Rust (`rust/tests/catalog_test.rs`)

Round-trips: each query returns the new MBID fields. Seed an artist (real UUID mbid), a release
(real `mbid`), a track with a `recording_mbid`; assert `albums_for_artist[0].album_artist_mbid`,
`tracks_for_album[0].recording_mbid` + `album_artist_mbid`, `tracks_for_paths[0]....` are the
expected UUIDs; and a synth/no-recording case yields the synth key / `None`.

### Dart (host-VM)

- `mbUrl` unit tests: a real UUID → `https://musicbrainz.org/<type>/<uuid>`; a `synth:aa:…` key →
  null; null/empty → null.
- Builder tests (`info_dialog_test.dart`): `albumInfoFields` includes a `Release MBID` field whose
  `.$3` is the release URL for a real mbid (and null for a synth release); `trackInfoFields` /
  `queueTrackInfoFields` include `Recording MBID` + `Album artist MBID` with the right URLs.
- Widget test: set `UrlLauncherPlatform.instance` to a mock; pump a dialog (or render the rows) with
  a real Release MBID, tap the link, and assert the mock received `https://musicbrainz.org/release/<uuid>`.

## Touched files

- `rust/src/catalog/schema.rs` — `Album` (+1), `Track` (+2), `QueueTrack` (+2).
- `rust/src/catalog/query.rs` — the three queries.
- `rust/src/frb_generated.rs`, `lib/src/rust/**` — regenerated bridge.
- `pubspec.yaml` (+ `pubspec.lock`) — `url_launcher`.
- `lib/widgets/info_dialog.dart` — `mbUrl`, field model, render, builders.
- `rust/tests/catalog_test.rs`, `test/info_dialog_test.dart`, a new `test/widgets/…` for the launch.

## Non-goals

- No artist Info popup is added (artists still have no Info menu item).
- The synth-keyed entities are shown but not linked (correct — they aren't on musicbrainz.org).
