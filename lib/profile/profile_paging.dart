import 'package:quax/client/client.dart';
import 'package:quax/profile/media_grid/media_grid_items/media_grid_item.dart';

/// Keeps dedupe identities tied to one refresh generation. A refresh invalidates
/// the old window synchronously, so a slower response from the previous refresh
/// cannot clear or repopulate the current window when it eventually completes.
class ProfilePageWindow<T> {
  final Object Function(T item) _identity;
  final _seen = <Object>{};
  int _generation = 0;

  ProfilePageWindow(this._identity);

  int capture() => _generation;

  void invalidate() => _generation++;

  bool isCurrent(int generation) => generation == _generation;

  List<T> apply(
    Iterable<T> items, {
    required int generation,
    required bool firstPage,
  }) {
    if (!isCurrent(generation)) return const [];
    if (firstPage) _seen.clear();
    return items.where((item) => _seen.add(_identity(item))).toList();
  }
}

/// Keeps the first occurrence of each chain across overlapping profile pages.
List<TweetChain> uniqueTweetChains(
  Iterable<TweetChain> chains,
  Set<String> seenIds,
) => chains.where((chain) => seenIds.add(chain.id)).toList();

/// Keeps the first occurrence of each tweet/media pair across overlapping grids.
List<MediaGridItem> uniqueMediaItems(
  Iterable<MediaGridItem> items,
  Set<({String tweetId, Object mediaId})> seen,
) => items.where((item) => seen.add(item.identity)).toList();
