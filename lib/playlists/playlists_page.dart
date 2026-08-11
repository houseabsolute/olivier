import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/src/rust/catalog/playlists.dart';
import 'package:olivier/state/playlists.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/state/browse_level.dart';
import 'package:olivier/state/list_selection.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/bilingual_text.dart';
import 'package:olivier/widgets/context_menu.dart';
import 'package:olivier/widgets/text_prompt_dialog.dart';

/// Pure reorder helper for ReorderableListView's `onReorderItem` callback,
/// where [newIndex] is already the post-removal destination (no adjustment).
List<T> reordered<T>(List<T> items, int oldIndex, int newIndex) {
  final copy = List<T>.of(items);
  final item = copy.removeAt(oldIndex);
  copy.insert(newIndex, item);
  return copy;
}

class PlaylistsPage extends ConsumerWidget {
  const PlaylistsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watched here, not inside the LayoutBuilder: its builder runs during
    // layout, and a provider watched from there registers its dependency in the
    // wrong phase — the next state change then asserts
    // `owner!._debugCurrentBuildTarget != null` when it tries to rebuild.
    final selected = ref.watch(selectedPlaylistProvider);
    final lists = ref.watch(playlistsProvider).value ?? const <Playlist>[];
    return LayoutBuilder(
      builder: (context, constraints) =>
          constraints.maxWidth < kNarrowBrowseWidth
              ? _narrow(context, ref, selected, lists)
              : _wide(context, ref),
    );
  }

  Widget _wide(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Playlists'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New playlist',
            onPressed: () => _newPlaylist(context, ref),
          ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: const [
          SizedBox(width: 280, child: _PlaylistSidebar()),
          VerticalDivider(width: 1),
          Expanded(child: _PlaylistDetail()),
        ],
      ),
    );
  }

  /// One pane at a time, like the browse cascade: the list, then the playlist
  /// you picked. Which one is showing is derived from the selection rather than
  /// tracked separately, so nothing can disagree about where we are.
  Widget _narrow(
    BuildContext context,
    WidgetRef ref,
    int? selected,
    List<Playlist> lists,
  ) {
    String? name;
    for (final p in lists) {
      if (p.id == selected) name = p.name;
    }

    return PopScope(
      // Back returns to the list before leaving the page.
      canPop: selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) ref.read(selectedPlaylistProvider.notifier).select(null);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: selected == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'All playlists',
                  onPressed: () =>
                      ref.read(selectedPlaylistProvider.notifier).select(null),
                ),
          title: Text(selected == null ? 'Playlists' : (name ?? 'Playlist')),
          actions: [
            if (selected == null)
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'New playlist',
                onPressed: () => _newPlaylist(context, ref),
              ),
          ],
        ),
        body: selected == null
            ? const _PlaylistSidebar()
            : const _PlaylistDetail(narrow: true),
      ),
    );
  }
}

Future<void> _newPlaylist(BuildContext context, WidgetRef ref) async {
  final name = await _promptName(context, title: 'New playlist');
  if (name == null || name.trim().isEmpty) return;
  final id = await ref.read(playlistsProvider.notifier).create(name.trim());
  ref.read(selectedPlaylistProvider.notifier).select(id);
}

Future<String?> _promptName(BuildContext context,
        {required String title, String initial = ''}) =>
    promptForText(context,
        title: title, initial: initial, hintText: 'Playlist name');

class _PlaylistSidebar extends ConsumerWidget {
  const _PlaylistSidebar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(playlistsProvider);
    final selected = ref.watch(selectedPlaylistProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Failed to load playlists: $e')),
      data: (lists) {
        if (lists.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No playlists yet. Use + to create one.'),
            ),
          );
        }
        return ReorderableListView.builder(
          itemCount: lists.length,
          onReorderItem: (oldIndex, newIndex) {
            final ids =
                reordered(lists, oldIndex, newIndex).map((p) => p.id).toList();
            ref.read(playlistsProvider.notifier).reorder(ids);
          },
          itemBuilder: (context, i) {
            final p = lists[i];
            return ListTile(
              key: ValueKey(p.id),
              title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${p.count} track${p.count == 1 ? '' : 's'}'),
              selected: p.id == selected,
              onTap: () =>
                  ref.read(selectedPlaylistProvider.notifier).select(p.id),
            );
          },
        );
      },
    );
  }
}

/// The paths a playlist-detail selection points at, in playlist order.
List<String> _selectedPaths(SelectionBinding selection, List<String> paths) =>
    [for (final key in selection.selectedKeys) paths[int.parse(key)]];

class _PlaylistDetail extends ConsumerWidget {
  const _PlaylistDetail({this.narrow = false});

  /// The playlist's name is in the app bar and the actions need to wrap: there
  /// is no room for the desktop header's single row at phone widths.
  final bool narrow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(selectedPlaylistProvider);
    if (id == null) {
      return const Center(child: Text('Select a playlist'));
    }
    final lists = ref.watch(playlistsProvider).value ?? const <Playlist>[];
    Playlist? playlist;
    for (final p in lists) {
      if (p.id == id) {
        playlist = p;
        break;
      }
    }
    final tracksAsync = ref.watch(playlistTracksProvider(id));
    final leads = ref.watch(languageLeadsProvider);

    return tracksAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Failed to load tracks: $e')),
      data: (tracks) {
        final paths = tracks.map((t) => t.path).toList();
        // Keyed by position, not path: a playlist may legitimately hold the
        // same track twice, so the path is not a unique row key.
        final selection = SelectionBinding(
          ref: ref,
          provider: playlistSelectionProvider,
          rowKeys: [for (var i = 0; i < tracks.length; i++) '$i'],
          selection: ref.watch(playlistSelectionProvider),
          singular: 'track',
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (!narrow)
                    SizedBox(
                      width: 200,
                      child: Text(
                        playlist?.name ?? '',
                        style: Theme.of(context).textTheme.titleLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  FilledButton(
                    onPressed: paths.isEmpty
                        ? null
                        : () => ref.read(playlistPlaybackProvider).play(paths),
                    child: const Text('Play'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: paths.isEmpty
                        ? null
                        : () =>
                            ref.read(playlistPlaybackProvider).shuffle(paths),
                    child: const Text('Shuffle'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: paths.isEmpty
                        ? null
                        : () => ref
                            .read(playlistPlaybackProvider)
                            .addToQueue(paths),
                    child: const Text('Add to queue'),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: 'Rename',
                    onPressed: () async {
                      final name = await _promptName(context,
                          title: 'Rename playlist',
                          initial: playlist?.name ?? '');
                      if (name != null && name.trim().isNotEmpty) {
                        await ref
                            .read(playlistsProvider.notifier)
                            .rename(id, name.trim());
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete',
                    onPressed: () async {
                      await ref.read(playlistsProvider.notifier).delete(id);
                      ref.read(selectedPlaylistProvider.notifier).select(null);
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: tracks.isEmpty
                  ? const Center(child: Text('This playlist is empty'))
                  : ReorderableListView.builder(
                      itemCount: tracks.length,
                      onReorderItem: (oldIndex, newIndex) {
                        final newPaths = reordered(paths, oldIndex, newIndex);
                        selection.clear(); // the positions just moved
                        ref
                            .read(playlistsProvider.notifier)
                            .setItems(id, newPaths);
                      },
                      itemBuilder: (context, i) {
                        final t = tracks[i];
                        return RowContextMenu(
                          key: ValueKey('${t.path}#$i'),
                          // Playlist rows are positions, not catalog entities;
                          // every handler below works off the selection, so the
                          // entity is only here for the menu's signature.
                          entity: const QueueEntityRef.track(0),
                          longPressToOpen: narrow,
                          onOpenSelection: () => selection.openMenu('$i'),
                          onAddToQueue: (_) => ref
                              .read(playlistPlaybackProvider)
                              .addToQueue(_selectedPaths(selection, paths)),
                          onRemoveFromPlaylist: (_) {
                            final drop =
                                selection.selectedKeys.map(int.parse).toSet();
                            final kept = [
                              for (var j = 0; j < paths.length; j++)
                                if (!drop.contains(j)) paths[j],
                            ];
                            selection.clear();
                            ref
                                .read(playlistsProvider.notifier)
                                .setItems(id, kept);
                          },
                          child: ListTile(
                            selected: selection.contains('$i'),
                            onTap: () => selection.tap('$i'),
                            title: BilingualText(
                              original: t.title,
                              translit: t.titleTranslit,
                              translate: t.titleTranslate,
                              leads: leads,
                            ),
                            subtitle: Text(t.artist ?? ''),
                            trailing: IconButton(
                              icon: const Icon(Icons.close),
                              tooltip: 'Remove',
                              onPressed: () {
                                final newPaths = List<String>.of(paths)
                                  ..removeAt(i);
                                selection.clear();
                                ref
                                    .read(playlistsProvider.notifier)
                                    .setItems(id, newPaths);
                              },
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
