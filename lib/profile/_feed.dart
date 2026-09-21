import 'package:material_ui/material_ui.dart';

import 'package:quax/client/client.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/tweet/conversation.dart';
import 'package:quax/ui/errors.dart';
import 'package:quax/ui/skeletons.dart';
import 'package:quax/user.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/utils/paging.dart';
import 'package:provider/provider.dart';

/// Loads one page of a profile timeline: the caller supplies the endpoint
/// through [loadPage] (posts, replies, likes…).
typedef ProfilePageLoader = Future<TweetStatus> Function(
    String? cursor, int Function() getTweetsCounter, void Function() incrementTweetsCounter);

/// A paginated tweet feed for a profile tab, shared by every endpoint that
/// answers with the usual user-timeline shape.
class ProfileTweetFeed extends StatefulWidget {
  final UserWithExtra user;
  final ProfilePageLoader loadPage;
  final String emptyMessage;

  const ProfileTweetFeed(
      {super.key, required this.user, required this.loadPage, required this.emptyMessage});

  @override
  State<ProfileTweetFeed> createState() => _ProfileTweetFeedState();
}

class _ProfileTweetFeedState extends State<ProfileTweetFeed> with AutomaticKeepAliveClientMixin<ProfileTweetFeed> {
  late final CursorPagingController<String, TweetChain> _paging;
  PagingController<int, TweetChain> get _pagingController => _paging.pagingController;

  int loadTweetsCounter = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _paging = CursorPagingController<String, TweetChain>(_fetchPage);
  }

  @override
  void dispose() {
    _paging.dispose();
    super.dispose();
  }

  void incrementLoadTweetsCounter() {
    ++loadTweetsCounter;
  }

  int getLoadTweetsCounter() {
    return loadTweetsCounter;
  }

  Future<CursorPage<String, TweetChain>> _fetchPage(String? cursor) async {
    var result = await widget.loadPage(cursor, getLoadTweetsCounter, incrementLoadTweetsCounter);

    // Stop when the cursor doesn't advance (or is gone), keeping the chains.
    final next = result.cursorBottom;
    return (items: result.chains, nextCursor: next == cursor ? null : next);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Consumer<TweetContextState>(builder: (context, model, child) {
      if (model.hideSensitive && (widget.user.possiblySensitive ?? false)) {
        return EmojiErrorWidget(
          emoji: '🍆🙈🍆',
          message: L10n.current.possibly_sensitive,
          errorMessage: L10n.current.possibly_sensitive_profile,
          onRetry: () async => model.setHideSensitive(false),
          retryText: L10n.current.yes_please,
        );
      }

      return RefreshIndicator(
        onRefresh: () async => _pagingController.refresh(),
        child: PagingListener<int, TweetChain>(
          controller: _pagingController,
          builder: (context, state, fetchNextPage) => PagedListView<int, TweetChain>(
            padding: EdgeInsets.zero,
            state: state,
            fetchNextPage: fetchNextPage,
            addAutomaticKeepAlives: false,
            // Same tuning as the home feed: build media ahead of the viewport
            // and fetch the next page a few chains before the bottom.
            cacheExtent: 1200,
            builderDelegate: PagedChildBuilderDelegate(
              invisibleItemsThreshold: 8,
              firstPageProgressIndicatorBuilder: (context) => const TweetListSkeleton(),
              itemBuilder: (context, chain, index) {
                return TweetConversation(
                    key: ValueKey(chain.id),
                    id: chain.id,
                    tweets: chain.tweets,
                    username: widget.user.screenName!,
                    isPinned: chain.isPinned);
              },
              firstPageErrorIndicatorBuilder: (context) => FullPageErrorWidget(
                error: pagingErrorOf(state)?.error,
                stackTrace: pagingErrorOf(state)?.stackTrace,
                prefix: L10n.of(context).unable_to_load_the_tweets,
                onRetry: fetchNextPage,
              ),
              newPageErrorIndicatorBuilder: (context) => FullPageErrorWidget(
                error: pagingErrorOf(state)?.error,
                stackTrace: pagingErrorOf(state)?.stackTrace,
                prefix: L10n.of(context).unable_to_load_the_next_page_of_tweets,
                onRetry: fetchNextPage,
              ),
              noItemsFoundIndicatorBuilder: (context) {
                return Center(child: Text(widget.emptyMessage));
              },
            ),
          ),
        ),
      );
    });
  }
}
