import 'package:material_ui/material_ui.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:quax/client/client.dart';
import 'package:quax/profile/media_grid/media_grid_items/media_grid_item.dart';
import 'package:quax/tweet/paginated_tweet_list.dart';
import 'package:quax/user.dart';
import 'package:quax/utils/paging.dart';

/// The last-page guard every cursor feed shares: pagination ends on an empty
/// page, a missing/blank cursor, or a cursor that did not advance.
///
/// Search is the feed that needed it most. X answers with the same bottom
/// cursor twice when a query's results run out, and without this the pager kept
/// requesting forever — each page burning a rate-limit slot and coming back all
/// duplicates. `_dedupe` hides the duplicates from the reader but does not stop
/// the requests.
String? nextCursorOrEnd(List<TweetChain> chains, String? next, String? cursor) {
  if (chains.isEmpty || next == null || next.isEmpty || next == cursor) return null;
  return next;
}

/// Holds the paging controller and loader for one tab of the tweet search
/// (Top / Latest). The query string is mutable — [updateQuery] swaps it in and
/// refreshes the controller so the next page request hits the new query.
class SearchTweetsPagination {
  final TweetFeedController feed = TweetFeedController();
  final String product;
  String _query;

  SearchTweetsPagination({required this.product, String initialQuery = ''}) : _query = initialQuery;

  Future<TweetPageResult> loadPage(String? cursor) async {
    if (_query.isEmpty) {
      return (chains: <TweetChain>[], nextCursor: null);
    }
    final result = await Twitter.searchTweets(_query, product: product, cursor: cursor);
    return (chains: result.chains, nextCursor: nextCursorOrEnd(result.chains, result.cursorBottom, cursor));
  }

  void updateQuery(String newQuery) {
    if (newQuery == _query) return;
    _query = newQuery;
    // reset() bumps the epoch; a raw refresh let the old query's in-flight page
    // write its cursor into the new chain.
    feed.reset();
  }

  void dispose() {
    feed.dispose();
  }
}

class SearchMediaPagination {
  late final CursorPagingController<String, MediaGridItem> _paging = CursorPagingController(_loadPage);
  String _query;

  SearchMediaPagination({String initialQuery = ''}) : _query = initialQuery;

  PagingController<int, MediaGridItem> get pagingController => _paging.pagingController;

  Future<CursorPage<String, MediaGridItem>> _loadPage(String? cursor) async {
    if (_query.isEmpty) {
      return (items: const <MediaGridItem>[], nextCursor: null);
    }
    final result = await Twitter.searchTweets(_query, product: 'Media', cursor: cursor);
    return mediaPageFromStatus(result, cursor);
  }

  void updateQuery(String newQuery) {
    if (newQuery == _query) return;
    _query = newQuery;
    _paging.reset();
  }

  void dispose() {
    _paging.dispose();
  }
}

class SearchUsersModel extends Store<List<UserWithExtra>> {
  SearchUsersModel() : super([]);

  Future<void> searchUsers(String query, BuildContext context) async {
    await execute(() async {
      if (query.isEmpty) {
        return [];
      } else {
        return await Twitter.searchUsers(query);
      }
    });
  }
}
