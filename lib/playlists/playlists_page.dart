import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/src/rust/catalog/playlists.dart';
import 'package:olivier/state/playlists.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/widgets/bilingual_text.dart';

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
}

Future<void> _newPlaylist(BuildContext context, WidgetRef ref) async {
  final name = await _promptName(context, title: 'New playlist');
  if (name == null || name.trim().isEmpty) return;
  final id = await ref.read(playlistsProvider.notifier).create(name.trim());
  ref.read(selectedPlaylistProvider.notifier).select(id);
}

Future<String?> _promptName(BuildContext context,
    {required String title, String initial = ''}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Playlist name'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('OK')),
      ],
    ),
  );
}

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

class _PlaylistDetail extends ConsumerWidget {
  const _PlaylistDetail();

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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
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
                        ref
                            .read(playlistsProvider.notifier)
                            .setItems(id, newPaths);
                      },
                      itemBuilder: (context, i) {
                        final t = tracks[i];
                        return ListTile(
                          key: ValueKey('${t.path}#$i'),
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
                              ref
                                  .read(playlistsProvider.notifier)
                                  .setItems(id, newPaths);
                            },
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
