import 'package:material_ui/material_ui.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/tweet/paginated_tweet_list.dart';
import 'package:quax/tweet/tweet_context_scope.dart';
import 'package:quax/user.dart';
import 'package:quax/utils/timeline_cache.dart';
import 'package:quax/utils/tweet_cache_index.dart';

final UserWithExtra user = UserWithExtra.fromArguments(idStr: "1", possiblySensitive: false, screenName: "ForYou");

class ForYouTweets extends StatefulWidget {
  final TweetFeedController feed;

  const ForYouTweets(this.feed, {super.key});

  @override
  State<ForYouTweets> createState() => _ForYouTweetsState();
}

class _ForYouTweetsState extends State<ForYouTweets> with AutomaticKeepAliveClientMixin<ForYouTweets> {
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
    final body = await TimelineCache.read(TimelineCache.keyFor('foryou'), maxAge: const Duration(hours: 12));
    if (body == null || !mounted) return;

    try {
      final chains = Twitter.previewForYouTweets(body).chains;
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
    final result = await Twitter.getTimelineTweets(
      user.idStr!,
      'profile',
      cursor: cursor,
      count: pageSize,
      includeReplies: false,
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
        username: user.screenName,
        onRefresh: () async {},
        firstPagePreview: _preview,
        firstPageErrorPrefix: L10n.of(context).unable_to_load_the_tweets,
        newPageErrorPrefix: L10n.of(context).unable_to_load_the_next_page_of_tweets,
        emptyMessage: L10n.of(context).unable_to_load_the_tweets_for_the_feed,
      ),
    );
  }
}
