import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/audio/queue_entity.dart';
import 'package:olivier/state/playlists.dart';
import 'package:olivier/state/providers.dart';

/// Show a picker to add [entity]'s tracks to an existing or new playlist.
Future<void> showAddToPlaylistDialog(
  BuildContext context,
  WidgetRef ref,
  QueueEntityRef entity,
) async {
  final fns = ref.read(playlistFnsProvider);
  final lists = await fns.list();
  if (!context.mounted) return;

  final newNameController = TextEditingController();
  final int? result;
  try {
    result = await showDialog<int>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Add to playlist'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (lists.isNotEmpty)
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final p in lists)
                          ListTile(
                            title: Text(p.name),
                            onTap: () => Navigator.of(context).pop(p.id),
                          ),
                      ],
                    ),
                  ),
                const Divider(),
                TextField(
                  controller: newNameController,
                  decoration: const InputDecoration(
                    hintText: 'New playlist name',
                    suffixIcon: Icon(Icons.add),
                  ),
                  onSubmitted: (v) async {
                    if (v.trim().isEmpty) return;
                    final id = await ref
                        .read(playlistsProvider.notifier)
                        .create(v.trim());
                    if (context.mounted) Navigator.of(context).pop(id);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  } finally {
    newNameController.dispose();
  }

  if (result == null) return;
  final paths =
      await resolveEntityPaths(entity, ref.read(entityPathFnsProvider));
  if (paths.isEmpty) return;
  await ref.read(playlistsProvider.notifier).addTracks(result, paths);
}
