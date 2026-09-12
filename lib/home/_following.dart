import 'package:material_ui/material_ui.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/tweet/paginated_tweet_list.dart';
import 'package:quax/tweet/tweet_context_scope.dart';
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
  @override
  bool get wantKeepAlive => true;

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
      // The client just stored this page: the posts join the offline shelf.
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
        firstPageErrorPrefix: L10n.of(context).unable_to_load_the_tweets,
        newPageErrorPrefix: L10n.of(context).unable_to_load_the_next_page_of_tweets,
        emptyMessage: L10n.of(context).unable_to_load_the_tweets_for_the_feed,
      ),
    );
  }
}
