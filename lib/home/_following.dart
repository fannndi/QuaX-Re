import 'package:material_ui/material_ui.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/tweet/paginated_tweet_list.dart';
import 'package:quax/tweet/tweet_context_scope.dart';
import 'package:quax/utils/timeline_cache.dart';
import 'package:quax/utils/tweet_cache_index.dart';

class FollowingTweets extends StatefulWidget {
  final TweetFeedController feed;

  const FollowingTweets(this.feed, {super.key});

  @override
  State<FollowingTweets> createState() => _FollowingTweetsState();
}

class _FollowingTweetsState extends State<FollowingTweets> with AutomaticKeepAliveClientMixin<FollowingTweets> {
  static const int pageSize = 20;
  int loadTweetsCounter = 0;
  List<TweetChain>? _preview;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  /// Paints the cached first page immediately; the network then revalidates
  /// and replaces it through the normal paging flow.
  Future<void> _loadPreview() async {
    final body = await TimelineCache.read(TimelineCache.keyFor('following'),
        maxAge: const Duration(hours: 12));
    if (body == null || !mounted) return;

    try {
      final chains = Twitter.previewFollowingTweets(body).chains;
      if (chains.isNotEmpty && mounted) {
        TweetCacheIndex().addAll(chains.map((chain) => chain.id));
        setState(() => _preview = chains);
      }
    } catch (_) {
      // A cache written by an older parser is simply ignored.
    }
  }

  void incrementLoadTweetsCounter() {
    ++loadTweetsCounter;
  }

  int getLoadTweetsCounter() {
    return loadTweetsCounter;
  }

  Future<TweetPageResult> _loadTweets(String? cursor) async {
    final result = await Twitter.getHomeLatestTimeline(
      cursor: cursor,
      count: pageSize,
      getTweetsCounter: getLoadTweetsCounter,
      incrementTweetsCounter: incrementLoadTweetsCounter,
    );
    if (cursor == null) {
      // The client just stored this page: the posts are now offline-readable.
      TweetCacheIndex().addAll(result.chains.map((chain) => chain.id));
    }
    return (chains: result.chains, nextCursor: result.cursorBottom);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return TweetContextScope(
      child: PaginatedTweetList(
        feed: widget.feed,
        loadPage: _loadTweets,
        username: null,
        onRefresh: () async {},
        firstPagePreview: _preview,
        firstPageErrorPrefix: L10n.of(context).unable_to_load_the_tweets,
        newPageErrorPrefix: L10n.of(context).unable_to_load_the_next_page_of_tweets,
        emptyMessage: L10n.of(context).unable_to_load_the_tweets_for_the_feed,
      ),
    );
  }
}
