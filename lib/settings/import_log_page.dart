import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/state/import_log.dart';

/// Read-only, copy-pasteable view of the import decision log, newest run at the
/// bottom (the view opens scrolled to the end). Backed by [importLogFnProvider].
class ImportLogPage extends ConsumerStatefulWidget {
  const ImportLogPage({super.key});

  @override
  ConsumerState<ImportLogPage> createState() => _ImportLogPageState();
}

class _ImportLogPageState extends ConsumerState<ImportLogPage> {
  late Future<String> _log;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _log = ref.read(importLogFnProvider)();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity & errors'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => setState(_reload),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear log',
            onPressed: () async {
              await ref.read(clearImportLogFnProvider)();
              if (mounted) setState(_reload);
            },
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: _log,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Could not read the log: ${snap.error}'),
              ),
            );
          }
          final text = snap.data ?? '';
          if (text.trim().isEmpty) {
            return Center(
              child: Text('No import activity logged yet.',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            );
          }
          // Resolve the log path for display. In tests the provider may be
          // unavailable (dbPathProvider not wired), so fall back gracefully.
          String? path;
          try {
            path = ref.read(importLogPathProvider);
          } catch (_) {
            path = null;
          }
          // Open scrolled to the bottom (newest run) after layout.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) {
              _scroll.jumpTo(_scroll.position.maxScrollExtent);
            }
          });
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (path != null) ...[
                Padding(
                  padding: const EdgeInsets.all(8),
                  child:
                      Text(path, style: Theme.of(context).textTheme.bodySmall),
                ),
                const Divider(height: 1),
              ],
              Expanded(
                child: Scrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(8),
                    child: SelectableText(
                      text,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
