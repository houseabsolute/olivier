import 'package:flutter/material.dart';

/// Which script leads in a bilingual row. `a` = reading/translation primary
/// (spec layout A, default); `b` = original primary (layout B).
enum LanguageLeads { a, b }

/// A fixed list-row extent (or bar height) that grows with the OS text size.
///
/// A bilingual row renders up to two lines, so a hard-coded extent that fits at
/// 1.0x text scaling overflows once accessibility text scaling enlarges those
/// lines. Scaling [base] by the ambient text scaler keeps the row proportional
/// to its text, so it never overflows — while preserving the perf benefit of a
/// fixed `itemExtent` (ListView can still compute scroll offsets without laying
/// every row out). The list rows carry no vertical padding, so the two text
/// lines are the only content; each base (48 for a list row, 80 for the
/// now-playing bar's title block) keeps a constant headroom over its lines at
/// every scale, since base and text grow by the same factor.
double bilingualRowExtent(BuildContext context, double base) =>
    MediaQuery.textScalerOf(context).scale(base);

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
/// - If the [original] is already Latin-script there is nothing to transliterate,
///   so it shows alone on one line (the reading only exists to make a non-Latin
///   original readable).
/// - Otherwise, any alternate equal to the original (e.g. a "translation" that
///   carries the original-script title) is dropped; the remaining reading and/or
///   translation form the alternate line. Layout A leads with that alternate,
///   layout B leads with the original. No distinct alternate ⇒ a single line.
BilingualLines resolveBilingual({
  required String original,
  required String? translit,
  required String? translate,
  required LanguageLeads leads,
}) {
  final orig = original.trim();

  // Latin-script original: nothing to transliterate — show it alone.
  if (_isLatin(orig)) {
    return BilingualLines(orig, null);
  }

  // Keep an alternate only if it's non-empty and actually differs from the
  // original (case-insensitively).
  String? keep(String? s) {
    final v = (s ?? '').trim();
    if (v.isEmpty || v.toLowerCase() == orig.toLowerCase()) return null;
    return v;
  }

  final reading = keep(translit);
  final translation = keep(translate);

  // The alternate line: reading and translation together when both exist,
  // otherwise whichever is present.
  final String? alt = (reading != null && translation != null)
      ? '$reading · $translation'
      : (reading ?? translation);

  if (alt == null) {
    return BilingualLines(orig, null);
  }

  switch (leads) {
    case LanguageLeads.a:
      return BilingualLines(alt, orig);
    case LanguageLeads.b:
      return BilingualLines(orig, alt);
  }
}

/// True when [s] is already Latin-script (Latin letters/accents, digits, common
/// punctuation) — nothing a reading helps with, so the row collapses to one
/// line. Non-Latin scripts (CJK, kana, Hangul, Cyrillic, Greek, …) keep their
/// reading.
bool _isLatin(String s) => s.runes.every(_isLatinRune);

bool _isLatinRune(int r) =>
    r <= 0x024F || // Basic Latin … Latin Extended-B (includes accents)
    (r >= 0x0300 && r <= 0x036F) || // combining diacritical marks
    (r >= 0x1E00 && r <= 0x1EFF) || // Latin Extended Additional
    (r >= 0x2000 && r <= 0x206F); // general punctuation (– — ' ' " " …)

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
