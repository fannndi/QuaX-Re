import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/tweet/paginated_tweet_list.dart';
import 'package:quax/tweet/tweet_context_scope.dart';
import 'package:quax/user.dart';
import 'package:quax/utils/image_prefetch.dart';
import 'package:quax/utils/tweet_freshness_index.dart';

final UserWithExtra user = UserWithExtra.fromArguments(idStr: "1", possiblySensitive: false, screenName: "ForYou");

class ForYouTweets extends StatefulWidget {
  final TweetFeedController feed;
  /// The login this feed belongs to; the scroll memory is kept per account so
  /// switching back restores the right place.
  final String? accountId;

  const ForYouTweets(this.feed, {super.key, this.accountId});

  @override
  State<ForYouTweets> createState() => _ForYouTweetsState();
}

class _ForYouTweetsState extends State<ForYouTweets> with AutomaticKeepAliveClientMixin<ForYouTweets> {
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
    // A refresh tells X what is already on screen, so the ranked feed answers
    // with different posts instead of the same launch slice.
    final seen = cursor == null
        ? widget.feed.items?.take(30).map((chain) => chain.id).toList()
        : null;

    final result = await Twitter.getTimelineTweets(
      user.idStr!,
      'profile',
      cursor: cursor,
      count: pageSize,
      includeReplies: false,
      seenTweetIds: seen,
      getTweetsCounter: getLoadTweetsCounter,
      incrementTweetsCounter: incrementLoadTweetsCounter,
    );
    if (kDebugMode) {
      // One greppable line per fetch: a rotated endpoint answers 404 (logged
      // by the client) and a stale ranked slice answers an unchanged page.
      debugPrint('QuaX foryou entries=${result.chains.length} cursor=${result.cursorBottom ?? '-'}');
    }
    TweetFreshnessIndex().note(result.chains.map((chain) => chain.id));
    if (mounted) {
      // Warm the pictures just below the viewport.
      unawaited(prefetchChainImages(context, result.chains));
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
        scrollKey: 'home.foryou.${widget.accountId ?? 'none'}',
        firstPageErrorPrefix: L10n.of(context).unable_to_load_the_tweets,
        newPageErrorPrefix: L10n.of(context).unable_to_load_the_next_page_of_tweets,
        emptyMessage: L10n.of(context).unable_to_load_the_tweets_for_the_feed,
      ),
    );
  }
}

