import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/playback_controller.dart';
import 'package:olivier/state/playlists.dart';
import 'package:olivier/state/providers.dart';

/// Multi-row selection over one list, as a set of stable row keys plus the
/// anchor a Shift-range extends from. Each list picks its own key space (an
/// MBID, a track id, a row index — see the providers at the bottom of this
/// file); nothing here interprets them beyond equality and list order.
@immutable
class ListSelection {
  const ListSelection({this.keys = const <String>{}, this.anchor});

  final Set<String> keys;

  /// The row a Shift-click extends from — the last row touched without Shift.
  final String? anchor;

  bool contains(String key) => keys.contains(key);
  int get length => keys.length;
  bool get isEmpty => keys.isEmpty;

  /// More than one row is selected, i.e. actions should target the selection
  /// rather than the row they were invoked on.
  bool get isMulti => keys.length > 1;

  /// [keys] in list order, so actions run over the rows as displayed rather
  /// than in the arbitrary order they were clicked in.
  List<String> ordered(List<String> rowKeys) => [
        for (final k in rowKeys)
          if (keys.contains(k)) k
      ];

  @override
  bool operator ==(Object other) =>
      other is ListSelection &&
      anchor == other.anchor &&
      setEquals(keys, other.keys);

  @override
  int get hashCode => Object.hash(anchor, Object.hashAllUnordered(keys));

  @override
  String toString() => 'ListSelection(${keys.toList()}, anchor: $anchor)';
}

/// Which selection gesture a click carries. Plain clicks keep their old
/// meaning (select this row and drill into it); only a modifier multi-selects.
enum SelectionModifier { none, toggle, range }

/// The modifier held right now. Read from the keyboard rather than the tap
/// event because `InkWell.onTap` doesn't report modifiers.
SelectionModifier currentSelectionModifier() {
  final keyboard = HardwareKeyboard.instance;
  if (keyboard.isShiftPressed) return SelectionModifier.range;
  // Meta so a Mac's ⌘ works the way Ctrl does elsewhere.
  if (keyboard.isControlPressed || keyboard.isMetaPressed) {
    return SelectionModifier.toggle;
  }
  return SelectionModifier.none;
}

/// The selection after clicking [key] in a list whose rows are [rowKeys].
///
/// Plain click replaces the selection with the clicked row; Ctrl/⌘ toggles that
/// one row and leaves the rest; Shift takes the run between the anchor and the
/// clicked row. A Shift-click with no usable anchor (nothing selected yet, or
/// an anchor that has since left the list) degrades to a plain click rather
/// than selecting nothing.
ListSelection applyRowTap({
  required ListSelection current,
  required List<String> rowKeys,
  required String key,
  required SelectionModifier modifier,
}) {
  switch (modifier) {
    case SelectionModifier.none:
      return ListSelection(keys: {key}, anchor: key);
    case SelectionModifier.toggle:
      final keys = Set<String>.of(current.keys);
      if (!keys.remove(key)) keys.add(key);
      return ListSelection(keys: keys, anchor: key);
    case SelectionModifier.range:
      final anchor = current.anchor;
      final from = anchor == null ? -1 : rowKeys.indexOf(anchor);
      final to = rowKeys.indexOf(key);
      if (from < 0 || to < 0) return ListSelection(keys: {key}, anchor: key);
      final lo = from < to ? from : to;
      final hi = from < to ? to : from;
      return ListSelection(
        keys: {for (var i = lo; i <= hi; i++) rowKeys[i]},
        // The anchor stays put so dragging the range back and forth with
        // successive Shift-clicks keeps growing from the same end.
        anchor: anchor,
      );
  }
}

/// One list's selection. [watchResets] watches whatever means the list is now
/// showing different rows (a new artist, a new album, a mutated queue); when
/// that changes the notifier rebuilds, dropping keys that no longer address
/// anything.
class RowSelection extends Notifier<ListSelection> {
  RowSelection({this.watchResets});

  final void Function(Ref ref)? watchResets;

  @override
  ListSelection build() {
    watchResets?.call(ref);
    return const ListSelection();
  }

  void tap(List<String> rowKeys, String key, SelectionModifier modifier) {
    state = applyRowTap(
      current: state,
      rowKeys: rowKeys,
      key: key,
      modifier: modifier,
    );
  }

  /// Fold the row a context menu was opened on into the selection: a row
  /// outside it replaces the whole selection (right-clicking elsewhere means
  /// "operate on this instead"), a row already in it leaves it untouched.
  void ensureContains(String key) {
    if (!state.contains(key)) {
      state = ListSelection(keys: {key}, anchor: key);
    }
  }

  void clear() => state = const ListSelection();
}

/// Album rows in the browse cascade; reset when the artist changes.
final albumSelectionProvider = NotifierProvider<RowSelection, ListSelection>(
  () => RowSelection(watchResets: (ref) => ref.watch(selectedArtistProvider)),
);

/// Album rows on the albums-by-date-added page; reset when the order flips.
final albumsByAddedSelectionProvider =
    NotifierProvider<RowSelection, ListSelection>(
  () => RowSelection(
      watchResets: (ref) => ref.watch(albumsAddedNewestFirstProvider)),
);

/// Track rows in the browse cascade; reset when the album changes.
final trackSelectionProvider = NotifierProvider<RowSelection, ListSelection>(
  () => RowSelection(watchResets: (ref) => ref.watch(selectedAlbumProvider)),
);

/// Queue rows, keyed by canonical index. Every structural queue change
/// renumbers them, so the selection resets whenever the queue revises.
final queueSelectionProvider = NotifierProvider<RowSelection, ListSelection>(
  () => RowSelection(watchResets: (ref) => ref.watch(queueRevisionProvider)),
);

/// Playlist-detail rows, keyed by position; reset when the playlist changes.
final playlistSelectionProvider = NotifierProvider<RowSelection, ListSelection>(
  () => RowSelection(watchResets: (ref) => ref.watch(selectedPlaylistProvider)),
);

/// The queue controller's revision counter, surfaced as a provider so
/// selection state can reset on every structural queue change.
class QueueRevision extends Notifier<int> {
  @override
  int build() {
    final controller = ref.watch(queueControllerProvider);
    void onRevision() => state = controller.revision.value;
    controller.revision.addListener(onRevision);
    ref.onDispose(() => controller.revision.removeListener(onRevision));
    return controller.revision.value;
  }
}

final queueRevisionProvider =
    NotifierProvider<QueueRevision, int>(QueueRevision.new);

/// "3 albums" / "1 track" — the noun phrase a multi-row menu entry names, or
/// null when only one row is selected and the single-row menu applies.
String? selectionLabel(ListSelection selection, String singular) {
  if (!selection.isMulti) return null;
  return '${selection.length} ${singular}s';
}

/// The multi-select wiring for one list, built once per build from its
/// selection provider and the keys of the rows on screen. Every list does the
/// same three things — highlight selected rows, route taps through the
/// modifier rules, and hand the context menu a settled selection — so they do
/// it through this rather than each repeating the plumbing.
class SelectionBinding {
  const SelectionBinding({
    required this.ref,
    required this.provider,
    required this.rowKeys,
    required this.selection,
    required this.singular,
  });

  final WidgetRef ref;
  final NotifierProvider<RowSelection, ListSelection> provider;

  /// Keys of every row in the list, in display order — the space a Shift-range
  /// runs over and the order bulk actions are applied in.
  final List<String> rowKeys;
  final ListSelection selection;

  /// What one row is called in menu text ('album', 'track').
  final String singular;

  bool contains(String key) => selection.contains(key);

  /// Apply a click to the selection. Returns true for a plain (unmodified)
  /// click, which still means "open this row" — the caller does its usual
  /// navigation then. A modified click only changes the selection.
  bool tap(String key) {
    final modifier = currentSelectionModifier();
    ref.read(provider.notifier).tap(rowKeys, key, modifier);
    return modifier == SelectionModifier.none;
  }

  /// `onOpenSelection` for a row: fold it into the selection, then say whether
  /// the menu is speaking for several rows.
  String? openMenu(String key) {
    ref.read(provider.notifier).ensureContains(key);
    return selectionLabel(ref.read(provider), singular);
  }

  /// The selected keys in display order. Read at action time (not from the
  /// captured [selection]) because `openMenu` may have just changed it.
  List<String> get selectedKeys => ref.read(provider).ordered(rowKeys);

  void clear() => ref.read(provider.notifier).clear();
}
