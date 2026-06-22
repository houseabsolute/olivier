import 'package:flutter/material.dart';

// Brand colors from the app icon's three rising notes (assets/icon/olivier.svg).
const _blue = Color(0xFF56A3D9); // high note — general-highlight accent
const _red = Color(0xFFE4572E); // low note — now-playing marker
// gold #F4B400 (middle note) is reserved/unused in v1.

const _surface = Color(0xFFF5F6FB); // faint-indigo off-white background
const _surfaceHighest = Color(0xFFE8EAF3); // neutral elevated surfaces
const _onSurface = Color(0xFF2B2D38); // dark indigo-grey text
const _onSurfaceVariant = Color(0xFF64667B); // muted text
const _outlineVariant = Color(0xFFDDDFEB); // dividers

/// Olivier's light theme: a faint-indigo neutral base with dark-grey text, blue
/// for general highlights, and red reserved for the now-playing track. Built
/// from a blue seed (for a complete, valid tonal palette) with the brand roles
/// pinned exactly. `surfaceTint` is neutralized so elevated surfaces (the
/// now-playing bar, dialogs, menus) stay neutral instead of taking a blue tint.
ThemeData olivierTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: _blue,
    brightness: Brightness.light,
  ).copyWith(
    primary: _blue,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFD7E9F7),
    onPrimaryContainer: const Color(0xFF15506F),
    tertiary: _red,
    onTertiary: Colors.white,
    tertiaryContainer: const Color(0xFFF8E0D6),
    onTertiaryContainer: const Color(0xFF7C2E16),
    surface: _surface,
    onSurface: _onSurface,
    onSurfaceVariant: _onSurfaceVariant,
    outlineVariant: _outlineVariant,
    surfaceContainerHighest: _surfaceHighest,
    surfaceTint: _surface,
    error: const Color(0xFFBA1A1A),
    onError: Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
  );
}
