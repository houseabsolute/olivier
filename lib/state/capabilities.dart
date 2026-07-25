import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether this device owns its catalog, or merely plays one built elsewhere.
///
/// On Android the catalog is a snapshot the desktop published (see
/// `docs/superpowers/specs/2026-07-25-android-synced-player-design.md`): the
/// phone never scans and never enriches, and nothing it changed would survive
/// the next import anyway. Worse, a scan there would walk the synced music
/// folder and rewrite the catalog the desktop owns — so these actions are
/// hidden rather than merely discouraged.
///
/// One flag rather than several: scanning, enrichment and tag/override editing
/// all mutate the same desktop-owned catalog, and there is no coherent state in
/// which the phone should have one but not the others.
final canModifyCatalogProvider = Provider<bool>((ref) => !Platform.isAndroid);
