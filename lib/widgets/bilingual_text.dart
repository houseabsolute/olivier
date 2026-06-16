import 'package:flutter/material.dart';

/// Which script leads in a bilingual row. `a` = reading/translation primary
/// (spec layout A, default); `b` = original primary (layout B).
enum LanguageLeads { a, b }

/// The two lines a bilingual row renders. [secondary] is null when the row
/// collapses to a single line (Latin-only, or no distinct alternate).
class BilingualLines {
  const BilingualLines(this.primary, this.secondary);
  final String primary;
  final String? secondary;
}

/// Compute the (primary, secondary) lines for a bilingual entry.
///
/// - A *name* passes only [translit] (a reading); a *title* may pass both a
///   [translit] (romaji) and a [translate] (English).
/// - Layout A leads with the reading/translation; layout B leads with the
///   original. When no distinct alternate exists the row collapses to one line.
BilingualLines resolveBilingual({
  required String original,
  required String? translit,
  required String? translate,
  required LanguageLeads leads,
}) {
  final t1 = (translit ?? '').trim();
  final t2 = (translate ?? '').trim();
  final orig = original.trim();

  // Build the "alternate" line: romaji and translation together when both
  // exist (titles), otherwise whichever is present.
  final String alt;
  if (t1.isNotEmpty && t2.isNotEmpty) {
    alt = '$t1 · "$t2"';
  } else if (t1.isNotEmpty) {
    alt = t1;
  } else {
    alt = t2; // may be empty
  }

  // Collapse: no alternate, or the alternate is just the original again.
  final altIsRedundant = alt.isEmpty ||
      alt.toLowerCase() == orig.toLowerCase() ||
      (t2.isEmpty && t1.toLowerCase() == orig.toLowerCase());
  if (altIsRedundant) {
    return BilingualLines(orig, null);
  }

  switch (leads) {
    case LanguageLeads.a:
      return BilingualLines(alt, orig);
    case LanguageLeads.b:
      return BilingualLines(orig, alt);
  }
}

/// Renders an entry's original plus its reading/translation as one or two
/// lines, per the current [leads] mode. The primary line uses [primaryStyle]
/// (defaults to the ambient body style); the secondary is dimmer/smaller.
///
/// [prefix]/[suffix] are a pure *rendering* concern: they are applied to the
/// **leading (primary) line only**, AFTER [resolveBilingual] has chosen which
/// of original/reading/translation leads. That keeps a year suffix or a
/// track-number prefix glued to the top line in BOTH layouts (in layout A it
/// rides the reading/translation line; in layout B it rides the original
/// line) and, crucially, in the translate-only case (where the leading line
/// is the translation, not the original). [resolveBilingual] itself never
/// sees them, so the bilingual pair is unaffected.
class BilingualText extends StatelessWidget {
  const BilingualText({
    super.key,
    required this.original,
    required this.translit,
    required this.translate,
    required this.leads,
    this.prefix,
    this.suffix,
    this.primaryStyle,
  });

  final String original;
  final String? translit;
  final String? translate;
  final LanguageLeads leads;
  final String? prefix;
  final String? suffix;
  final TextStyle? primaryStyle;

  @override
  Widget build(BuildContext context) {
    final lines = resolveBilingual(
      original: original,
      translit: translit,
      translate: translate,
      leads: leads,
    );
    // Decorate the leading line only, after primary/secondary is chosen.
    final primary = '${prefix ?? ''}${lines.primary}${suffix ?? ''}';
    final theme = Theme.of(context);
    final secondaryStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    if (lines.secondary == null) {
      return Text(
        primary,
        style: primaryStyle,
        overflow: TextOverflow.ellipsis,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(primary, style: primaryStyle, overflow: TextOverflow.ellipsis),
        Text(lines.secondary!,
            style: secondaryStyle, overflow: TextOverflow.ellipsis),
      ],
    );
  }
}
