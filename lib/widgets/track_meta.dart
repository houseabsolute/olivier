import 'package:flutter/material.dart';

// Shared column widths so TrackMetaHeader aligns with TrackMeta's columns.
const double kTrackMetaLenWidth = 44;
const double kTrackMetaDateWidth = 80;
const double kTrackMetaGap = 12;

/// Right-aligned trailing metadata columns for a track/queue row: length, date
/// added, and last played. Compact and muted; the two dates carry tooltips to
/// disambiguate them. [addedAt]/[lastPlayed] are unix seconds (0 / null = none).
class TrackMeta extends StatelessWidget {
  const TrackMeta({
    super.key,
    required this.lengthMs,
    required this.addedAt,
    required this.lastPlayed,
  });

  final BigInt? lengthMs;
  final int addedAt;
  final int? lastPlayed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: scheme.onSurfaceVariant);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: kTrackMetaLenWidth,
          child:
              Text(_fmtLen(lengthMs), textAlign: TextAlign.right, style: style),
        ),
        const SizedBox(width: kTrackMetaGap),
        SizedBox(
          width: kTrackMetaDateWidth,
          child: Tooltip(
            message: 'Date added',
            child: Text(_fmtDate(addedAt),
                textAlign: TextAlign.right, style: style),
          ),
        ),
        const SizedBox(width: kTrackMetaGap),
        SizedBox(
          width: kTrackMetaDateWidth,
          child: Tooltip(
            message: 'Last played',
            child: Text(_fmtDate(lastPlayed ?? 0),
                textAlign: TextAlign.right, style: style),
          ),
        ),
      ],
    );
  }
}

/// Right-aligned column-title header aligned with [TrackMeta]'s columns.
class TrackMetaHeader extends StatelessWidget {
  const TrackMetaHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        );
    Widget col(double w, String label) => SizedBox(
          width: w,
          child: Text(label, textAlign: TextAlign.right, style: style),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        col(kTrackMetaLenWidth, 'Length'),
        const SizedBox(width: kTrackMetaGap),
        col(kTrackMetaDateWidth, 'Added'),
        const SizedBox(width: kTrackMetaGap),
        col(kTrackMetaDateWidth, 'Played'),
      ],
    );
  }
}

String _fmtLen(BigInt? ms) {
  if (ms == null) return '';
  final s = (ms ~/ BigInt.from(1000)).toInt();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Local `YYYY-MM-DD`; `—` for unknown (unix seconds <= 0).
String _fmtDate(int secs) {
  if (secs <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(secs * 1000);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}
