import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/settings/import_log_page.dart';
import 'package:olivier/src/rust/api/sync.dart';
import 'package:olivier/state/enrich_controller.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/scan_controller.dart';
import 'package:olivier/state/sync_export_controller.dart';
import 'package:olivier/state/sync_import_controller.dart';
import 'package:olivier/widgets/bilingual_text.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scan = ref.watch(scanControllerProvider);
    final enrich = ref.watch(enrichControllerProvider);
    final leads = ref.watch(languageLeadsProvider);
    final sync = ref.watch(syncExportControllerProvider);
    final import = ref.watch(syncImportControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Music folders', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (scan.roots.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'No music folders yet. Add one to build your library.',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
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
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Add folder'),
                onPressed: () => _addFolder(ref),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Rescan all'),
                onPressed: scan.roots.isEmpty
                    ? null
                    : () =>
                        ref.read(scanControllerProvider.notifier).rescanAll(),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.library_add_outlined),
                label: const Text('Check for new music'),
                onPressed: scan.roots.isEmpty
                    ? null
                    : () => ref
                        .read(scanControllerProvider.notifier)
                        .findNewFiles(),
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
                Icon(Icons.error_outline,
                    color: Theme.of(context).colorScheme.error, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Error: ${scan.lastError}',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Text('Music metadata',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Fetch readings, translations, and original dates from MusicBrainz '
            'for your tagged files. Runs automatically after a scan.',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                Icon(Icons.error_outline,
                    color: Theme.of(context).colorScheme.error, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Enrich error: ${enrich.lastError}',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Text('Display', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Language leads: which script shows first in bilingual rows.',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
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
          if (Platform.isAndroid) ...[
            const SizedBox(height: 24),
            Text('Synced library',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'This device plays a library synced from the desktop. The '
              'catalog is imported from the snapshot Syncthing delivers; '
              'scanning and metadata lookup happen on the desktop.',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            if (!import.hasStoragePermission)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline,
                        size: 18, color: Theme.of(context).colorScheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'All-files access is needed: the catalog snapshot is a '
                        '.db file, which the audio-only permission cannot read.',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  ],
                ),
              ),
            FilledButton.icon(
              icon: const Icon(Icons.sync),
              label: Text(import.running ? 'Importing…' : 'Import from sync'),
              onPressed: import.running
                  ? null
                  : () => ref
                      .read(syncImportControllerProvider.notifier)
                      .importIfNewer(interactive: true),
            ),
            if (import.running)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
            if (import.lastResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  import.lastResult!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            if (import.lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Import error: ${import.lastError}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
          const SizedBox(height: 24),
          Text('Phone sync', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Write a copy of your library catalog for a phone that already has '
            'the music files. Put it in a folder Syncthing replicates to the '
            'device; the phone imports it and plays from its own copy.',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Destination folder'),
            subtitle: Text(
              sync.destDir ?? 'Not set',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
            trailing: OutlinedButton(
              onPressed: () => _chooseSyncDest(ref),
              child: const Text('Choose'),
            ),
          ),
          // One explicit destination per folder. Showing the actual rewrite
          // matters: a wrong path exports cleanly and produces a catalog of
          // dead links on the phone, with nothing to report the mistake.
          for (final m
              in ref.read(syncExportControllerProvider.notifier).mappingsFor(
                    scan.roots,
                  ))
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                m.desktop,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              subtitle: Text(
                'on the phone:  ${m.phone}',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              trailing: OutlinedButton(
                onPressed: () => _editPhoneRoot(context, ref, m),
                child: const Text('Edit'),
              ),
            ),
          if (_syncProblem(ref, scan.roots) case final problem?)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline,
                      size: 18, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      problem,
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            icon: const Icon(Icons.phone_android_outlined),
            label: Text(sync.exporting ? 'Exporting…' : 'Export for phone'),
            onPressed: ref
                        .read(syncExportControllerProvider.notifier)
                        .canExport(scan.roots) &&
                    !scan.scanning &&
                    _syncProblem(ref, scan.roots) == null
                ? () => ref
                    .read(syncExportControllerProvider.notifier)
                    .export(scan.roots)
                : null,
          ),
          if (scan.scanning)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Finish scanning first — a snapshot taken mid-scan would be '
                'missing tracks.',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          if (sync.exporting)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          if (sync.lastResult != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Exported ${sync.lastResult}',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          if (sync.lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline,
                      size: 18, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Export error: ${sync.lastError}',
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 24),
          Text('Diagnostics', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('Activity & errors'),
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

  Future<void> _chooseSyncDest(WidgetRef ref) async {
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null) return;
    await ref.read(syncExportControllerProvider.notifier).setDestDir(dir);
  }

  /// The problem the current mapping would hit, surfaced before export rather
  /// than as a Rust error string afterwards.
  String? _syncProblem(WidgetRef ref, List<String> roots) {
    if (roots.isEmpty) return null;
    return mappingProblem(
      ref.read(syncExportControllerProvider.notifier).mappingsFor(roots),
    );
  }

  Future<void> _editPhoneRoot(
    BuildContext context,
    WidgetRef ref,
    RootMapping mapping,
  ) async {
    final controller = TextEditingController(text: mapping.phone);
    try {
      final value = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Location on the phone'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                mapping.desktop,
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  helperText:
                      'The absolute path this folder syncs to on the device.',
                ),
                onSubmitted: (v) => Navigator.of(ctx).pop(v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      final trimmed = value?.trim();
      if (trimmed == null || trimmed.isEmpty) return;
      await ref
          .read(syncExportControllerProvider.notifier)
          .setPhoneRoot(mapping.desktop, trimmed);
    } finally {
      controller.dispose();
    }
  }

  Future<void> _addFolder(WidgetRef ref) async {
    final dir = await FilePicker.getDirectoryPath();
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
