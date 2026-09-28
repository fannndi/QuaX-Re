import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/cached/cached_tweets_model.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/home/home_events.dart';
import 'package:quax/tweet/paginated_tweet_list.dart';
import 'package:quax/tweet/tweet_context_scope.dart';
import 'package:quax/user.dart';
import 'package:quax/utils/image_prefetch.dart';
import 'package:quax/utils/tweet_freshness_index.dart';

final UserWithExtra user = UserWithExtra.fromArguments(
  idStr: "1",
  possiblySensitive: false,
  screenName: "ForYou",
);

class ForYouTweets extends StatefulWidget {
  final TweetFeedController feed;

  /// The login this feed belongs to; the scroll memory is kept per account so
  /// switching back restores the right place.
  final String? accountId;

  const ForYouTweets(this.feed, {super.key, this.accountId});

  @override
  State<ForYouTweets> createState() => _ForYouTweetsState();
}

class _ForYouTweetsState extends State<ForYouTweets>
    with AutomaticKeepAliveClientMixin<ForYouTweets> {
  static const int pageSize = 20;
  static const int _maxRawPages = 6;

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
    // The always-new home: pages are drained until a post the reader has not
    // seen yet shows up (or the timeline really ends), because anything seen
    // in an earlier session is filtered out below. The ranked feed keeps
    // re-serving older slices, so one page is often not enough.
    final all = <TweetChain>[];
    var pageCursor = cursor;
    var rawPages = 0;
    var previousCursor = cursor;

    while (true) {
      // A first fetch tells X what is already on screen, so the ranked feed
      // answers with different posts instead of the same launch slice.
      final seen = (pageCursor == null && cursor == null)
          ? widget.feed.items?.take(30).map((chain) => chain.id).toList()
          : null;

      final result = await Twitter.getTimelineTweets(
        user.idStr!,
        'profile',
        cursor: pageCursor,
        count: pageSize,
        includeReplies: false,
        seenTweetIds: seen,
        getTweetsCounter: getLoadTweetsCounter,
        incrementTweetsCounter: incrementLoadTweetsCounter,
      );
      rawPages++;
      previousCursor = pageCursor;
      pageCursor = result.cursorBottom;

      final split = CachedTweetModel.splitByFreshness(result.chains);
      all.addAll(split.fresh);
      // Archive every loaded chain (freshest copy wins): the Offline tab is
      // this page's legacy, whether the reader saw it now or not. The ids go
      // into the freshness snapshot too, so the next launch hides them.
      unawaited(
        CachedTweetModel().archive(
          result.chains,
          source: CachedFeedSource.foryou,
        ),
      );
      TweetFreshnessIndex().note(result.chains.map((chain) => chain.id));

      final drained =
          split.fresh.isNotEmpty ||
          result.cursorBottom == null ||
          result.cursorBottom!.isEmpty ||
          result.cursorBottom == previousCursor ||
          rawPages >= _maxRawPages;
      if (drained) {
        if (kDebugMode) {
          // One greppable line per fetch: a rotated endpoint answers 404
          // (logged by the client) and a stale ranked slice answers an
          // unchanged page.
          debugPrint(
            'QuaX foryou raw=$rawPages fresh=${all.length} '
            'cursor=${result.cursorBottom ?? '-'}',
          );
        }
        if (mounted) {
          // Warm the pictures just below the viewport.
          unawaited(prefetchChainImages(context, split.fresh));
        }
        return (chains: all, nextCursor: result.cursorBottom);
      }
    }
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.new_releases_outlined, size: 48),
            const SizedBox(height: 12),
            Text(L10n.of(context).no_new_posts, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              L10n.of(context).no_new_posts_details,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () => offlineTabRequest.value++,
              icon: const Icon(Icons.offline_pin_outlined),
              label: Text(L10n.of(context).open_archive),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return TweetContextScope(
      child: PaginatedTweetList(
        feed: widget.feed,
        loadPage: _loadTweets,
        username: user.screenName,
        scrollKey: 'home.foryou.${widget.accountId ?? 'none'}',
        firstPageErrorPrefix: L10n.of(context).unable_to_load_the_tweets,
        newPageErrorPrefix: L10n.of(context)
            .unable_to_load_the_next_page_of_tweets,
        emptyMessage: L10n.of(context).unable_to_load_the_tweets_for_the_feed,
        emptyBuilder: _buildEmpty,
        // The home fetches once per app open: no pull-to-refresh, no auto
        // refresh on resume — the next fetch is the next launch.
        refreshOnResume: false,
      ),
    );
  }
}
