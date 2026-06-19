import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/settings/import_log_page.dart';
import 'package:olivier/state/enrich_controller.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/scan_controller.dart';
import 'package:olivier/widgets/bilingual_text.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scan = ref.watch(scanControllerProvider);
    final enrich = ref.watch(enrichControllerProvider);
    final leads = ref.watch(languageLeadsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Music folders', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (scan.roots.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'No music folders yet. Add one to build your library.',
                style: TextStyle(color: Colors.grey),
              ),
            )
          else
            ...scan.roots.map(
              (root) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  root,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove folder',
                  onPressed: () => _confirmRemove(context, ref, root),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Add folder'),
                onPressed: () => _addFolder(ref),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Rescan all'),
                onPressed: scan.roots.isEmpty
                    ? null
                    : () =>
                        ref.read(scanControllerProvider.notifier).rescanAll(),
              ),
            ],
          ),
          if (scan.scanning) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Scanning… ${scan.filesSeen} files'
                    ' (${scan.filesChanged} new)'
                    '${scan.queued > 0 ? " · ${scan.queued} queued" : ""}',
                  ),
                ),
              ],
            ),
          ],
          if (scan.lastError != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Error: ${scan.lastError}',
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Text('Music metadata',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Fetch readings, translations, and original dates from MusicBrainz '
            'for your tagged files. Runs automatically after a scan.',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.translate),
                label: const Text('Enrich library'),
                onPressed: enrich.running
                    ? null
                    : () =>
                        ref.read(enrichControllerProvider.notifier).enrich(),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.cloud_sync_outlined),
                label: const Text('Re-fetch from MusicBrainz'),
                onPressed: enrich.running
                    ? null
                    : () => ref
                        .read(enrichControllerProvider.notifier)
                        .refreshFromMusicBrainz(),
              ),
            ],
          ),
          if (enrich.running) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Enriching… ${enrich.entitiesDone}'
                    '${enrich.entitiesTotal > 0 ? "/${enrich.entitiesTotal}" : ""}'
                    '${enrich.current.isNotEmpty ? " · ${enrich.current}" : ""}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          if (enrich.lastError != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Enrich error: ${enrich.lastError}',
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Text('Display', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Language leads: which script shows first in bilingual rows.',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 8),
          SegmentedButton<LanguageLeads>(
            segments: const [
              ButtonSegment(
                value: LanguageLeads.a,
                label: Text('Reading / translation (A)'),
              ),
              ButtonSegment(
                value: LanguageLeads.b,
                label: Text('Original (B)'),
              ),
            ],
            selected: {leads},
            onSelectionChanged: (sel) =>
                ref.read(languageLeadsProvider.notifier).set(sel.first),
          ),
          const SizedBox(height: 24),
          Text('Diagnostics', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('Import log'),
            subtitle: const Text(
              'What the scanner and enricher decided — de-dupe, removals, failures.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ImportLogPage()),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addFolder(WidgetRef ref) async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    await ref.read(scanControllerProvider.notifier).addFolder(dir);
  }

  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    String path,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove folder?'),
        content: Text(
          'Remove "$path"? Its tracks will be removed from your library.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(scanControllerProvider.notifier).removeFolder(path);
    }
  }
}
