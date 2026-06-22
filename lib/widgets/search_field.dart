import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';
import 'package:olivier/state/search.dart';

/// The global search box (lives in the app bar). Debounces input into
/// [searchQueryProvider]; arrow keys move the overlay highlight, Enter selects
/// the highlighted hit, Esc clears.
class SearchField extends ConsumerStatefulWidget {
  const SearchField({super.key});

  @override
  ConsumerState<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends ConsumerState<SearchField> {
  final _controller = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      ref.read(searchQueryProvider.notifier).set(v);
      ref.read(highlightedSearchIndexProvider.notifier).reset();
    });
  }

  List<SearchHit> _hits() {
    final r = ref.read(searchResultsProvider).value ??
        const SearchResults(artists: [], albums: [], tracks: []);
    return flattenHits(r);
  }

  void _move(int delta) {
    final hits = _hits();
    if (hits.isEmpty) return;
    final cur = ref.read(highlightedSearchIndexProvider);
    final next = (cur < 0 ? 0 : cur + delta).clamp(0, hits.length - 1);
    ref.read(highlightedSearchIndexProvider.notifier).set(next);
  }

  void _enter() {
    // Cancel any pending debounce so it can't re-set the query after we act.
    _debounce?.cancel();
    final hits = _hits();
    final i = ref.read(highlightedSearchIndexProvider);
    if (i >= 0 && i < hits.length) selectHit(ref, hits[i]);
  }

  void _escape() {
    // Cancel any pending debounce so it can't re-populate the just-cleared query.
    _debounce?.cancel();
    ref.read(searchQueryProvider.notifier).clear();
    ref.read(highlightedSearchIndexProvider.notifier).reset();
    ref.read(searchFocusNodeProvider).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(searchQueryProvider, (_, next) {
      if (next.isEmpty && _controller.text.isNotEmpty) _controller.clear();
    });
    final focus = ref.watch(searchFocusNodeProvider);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.enter): _enter,
        const SingleActivator(LogicalKeyboardKey.escape): _escape,
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: TextField(
          controller: _controller,
          focusNode: focus,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search, size: 18),
            hintText: 'Search',
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
          onChanged: _onChanged,
        ),
      ),
    );
  }
}
