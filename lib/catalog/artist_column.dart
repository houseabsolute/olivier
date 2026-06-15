import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olivier/src/rust/catalog/schema.dart';
import 'package:olivier/state/providers.dart';

class ArtistColumn extends ConsumerWidget {
  const ArtistColumn({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artistsAsync = ref.watch(artistsProvider);
    return artistsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (artists) => _ArtistList(artists: artists),
    );
  }
}

class _ArtistList extends ConsumerWidget {
  const _ArtistList({required this.artists});

  final List<Artist> artists;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedArtistProvider);
    if (artists.isEmpty) {
      return const Center(child: Text('No artists — scan a folder first'));
    }
    return ListView.builder(
      itemCount: artists.length,
      itemExtent: 48,
      scrollCacheExtent: const ScrollCacheExtent.pixels(600),
      itemBuilder: (context, index) {
        final artist = artists[index];
        final isSelected = selected == artist.mbid;
        return InkWell(
          key: ValueKey(artist.mbid),
          onTap: () =>
              ref.read(selectedArtistProvider.notifier).select(artist.mbid),
          child: Container(
            color: isSelected
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _RowLabel(text: artist.name),
          ),
        );
      },
    );
  }
}

class _RowLabel extends StatelessWidget {
  const _RowLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      overflow: TextOverflow.ellipsis,
    );
  }
}
