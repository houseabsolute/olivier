import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olivier/theme.dart';

void main() {
  test('olivierTheme pins the brand colors', () {
    final scheme = olivierTheme().colorScheme;
    expect(scheme.brightness, Brightness.light);
    expect(scheme.primary, const Color(0xFF56A3D9)); // blue — high note
    expect(scheme.tertiary, const Color(0xFFE4572E)); // red — low note
    expect(scheme.surface, const Color(0xFFF5F6FB)); // faint-indigo bg
    expect(scheme.onSurface, const Color(0xFF2B2D38)); // dark-grey text
    expect(scheme.onSurfaceVariant, const Color(0xFF64667B));
    expect(scheme.outlineVariant, const Color(0xFFDDDFEB));
    expect(scheme.primaryContainer, const Color(0xFFD7E9F7));
    expect(scheme.tertiaryContainer, const Color(0xFFF8E0D6));
    expect(scheme.surfaceContainerHighest, const Color(0xFFE8EAF3));
  });
}
