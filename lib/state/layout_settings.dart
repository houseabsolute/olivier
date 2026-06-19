import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/state/providers.dart';

const layoutArtistsKey = 'layout.artists';
const layoutRightPaneKey = 'layout.right_pane';
const layoutQueueHeightKey = 'layout.queue_height';

const defaultArtistFlex = (1.0, 2.0);
const defaultRightPaneFlex = (1.0, 1.0);
const defaultQueueHeight = 240.0;
const minQueueHeight = 80.0;

/// Persisted panel sizes. Flex pairs for the columns (resolution-independent);
/// a pixel height for the expanded queue.
class LayoutSettings {
  const LayoutSettings({
    required this.artistFlex,
    required this.rightPaneFlex,
    required this.queueHeight,
  });

  final (double, double) artistFlex;
  final (double, double) rightPaneFlex;
  final double queueHeight;

  static const defaults = LayoutSettings(
    artistFlex: defaultArtistFlex,
    rightPaneFlex: defaultRightPaneFlex,
    queueHeight: defaultQueueHeight,
  );
}

/// Parse `"f0,f1"` into a positive flex pair; [fallback] on any bad input.
(double, double) parseFlexPair(String? s, (double, double) fallback) {
  if (s == null) return fallback;
  final parts = s.split(',');
  if (parts.length != 2) return fallback;
  final a = double.tryParse(parts[0].trim());
  final b = double.tryParse(parts[1].trim());
  if (a == null || b == null || a <= 0 || b <= 0) return fallback;
  return (a, b);
}

String formatFlexPair((double, double) f) => '${f.$1},${f.$2}';

/// Parse a pixel height; [defaultQueueHeight] on bad input. (The widget clamps
/// to the current screen at use time.)
double parseQueueHeight(String? s) =>
    double.tryParse(s ?? '') ?? defaultQueueHeight;

/// Loads the persisted layout once via the settings seam, defaulting any
/// missing/garbage value.
final layoutSettingsProvider = FutureProvider<LayoutSettings>((ref) async {
  final get = ref.watch(getSettingFnProvider);
  final results = await Future.wait([
    get(layoutArtistsKey),
    get(layoutRightPaneKey),
    get(layoutQueueHeightKey),
  ]);
  return LayoutSettings(
    artistFlex: parseFlexPair(results[0], defaultArtistFlex),
    rightPaneFlex: parseFlexPair(results[1], defaultRightPaneFlex),
    queueHeight: parseQueueHeight(results[2]),
  );
});
