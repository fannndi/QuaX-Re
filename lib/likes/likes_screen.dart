import 'package:flutter_triple/flutter_triple.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/client.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/profile/_feed.dart';
import 'package:quax/saved/liked_tweet_model.dart';
import 'package:quax/saved/saved_screen.dart';
import 'package:quax/saved/saved_tweet_model.dart';
import 'package:quax/saved/saved_tweet_tile.dart';
import 'package:quax/tweet/tweet_context_scope.dart';
import 'package:quax/ui/errors.dart';
import 'package:quax/ui/skeletons.dart';
import 'package:quax/user.dart';

/// The Like tab: what was liked and saved inside the app (local database) next
/// to the real likes and bookmarks X holds for the active account. Four tabs,
/// mirroring the feed's For You / Following switch.
class LikesScreen extends StatefulWidget {
  final ScrollController scrollController;

  const LikesScreen({super.key, required this.scrollController});

  @override
  State<LikesScreen> createState() => _LikesScreenState();
}

class _LikesScreenState extends State<LikesScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(length: 4, vsync: this);

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TweetContextScope(
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: TabBar(
            controller: _tabController,
            tabs: [
              Tab(text: L10n.of(context).local),
              Tab(text: L10n.of(context).saved),
              Tab(text: L10n.of(context).profile),
              Tab(text: L10n.of(context).bookmarks),
            ],
          ),
          actions: [
            AnimatedBuilder(
              animation: _tabController,
              builder: (context, _) => switch (_tabController.index) {
                0 => IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: L10n.of(context).refresh,
                    onPressed: () => context.read<LikedTweetModel>().refreshLikedTweets(),
                  ),
                1 => IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: L10n.of(context).refresh,
                    onPressed: () => context.read<SavedTweetModel>().refreshSavedTweets(),
                  ),
                _ => const SizedBox.shrink(),
              },
            ),
          ],
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            _LocalLikes(scrollController: widget.scrollController),
            const SavedView(),
            const _ProfileLikes(),
            const _ProfileBookmarks(),
          ],
        ),
      ),
    );
  }
}

/// Locally liked posts, straight from the app's own database.
class _LocalLikes extends StatefulWidget {
  final ScrollController scrollController;

  const _LocalLikes({required this.scrollController});

  @override
  State<_LocalLikes> createState() => _LocalLikesState();
}

class _LocalLikesState extends State<_LocalLikes> with AutomaticKeepAliveClientMixin<_LocalLikes> {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    context.read<LikedTweetModel>().listLikedTweets();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final model = context.read<LikedTweetModel>();

    return ScopedBuilder<LikedTweetModel, List<LikedTweet>>.transition(
      store: model,
      onError: (_, e) => FullPageErrorWidget(
        error: e,
        stackTrace: null,
        prefix: L10n.current.unable_to_load_the_tweets,
        onRetry: () => model.listLikedTweets(),
      ),
      onLoading: (_) => const TweetListSkeleton(),
      onState: (_, likes) => RefreshIndicator(
        onRefresh: model.refreshLikedTweets,
        child: likes.isEmpty
            ? _EmptyLikes(message: L10n.of(context).no_liked_posts_yet)
            : ListView.builder(
                controller: widget.scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 4),
                itemCount: likes.length,
                itemBuilder: (context, index) =>
                    SavedTweetTile(id: likes[index].id, content: likes[index].content),
              ),
      ),
    );
  }
}

class _EmptyLikes extends StatelessWidget {
  final String message;

  const _EmptyLikes({required this.message});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(child: Text(message)),
        ),
      ),
    );
  }
}

/// The likes of the active account, fetched from X's Likes endpoint (X only
/// answers this for the requesting account itself).
class _ProfileLikes extends StatelessWidget {
  const _ProfileLikes();

  @override
  Widget build(BuildContext context) {
    return _ActiveAccountFeed(
      builder: (user) => ProfileTweetFeed(
        user: user,
        emptyMessage: L10n.of(context).no_liked_posts_yet,
        loadPage: (cursor, getTweetsCounter, incrementTweetsCounter) => Twitter.getLikes(
          user.idStr!,
          cursor: cursor,
          count: 20,
          getTweetsCounter: getTweetsCounter,
          incrementTweetsCounter: incrementTweetsCounter,
        ),
      ),
    );
  }
}

/// The posts the active account bookmarked, fetched from X's Bookmarks
/// endpoint (x.com/i/bookmarks) — again only for the requesting account.
class _ProfileBookmarks extends StatelessWidget {
  const _ProfileBookmarks();

  @override
  Widget build(BuildContext context) {
    return _ActiveAccountFeed(
      builder: (user) => ProfileTweetFeed(
        user: user,
        emptyMessage: L10n.of(context).no_bookmarks_yet,
        loadPage: (cursor, getTweetsCounter, incrementTweetsCounter) => Twitter.getBookmarks(
          cursor: cursor,
          count: 20,
          getTweetsCounter: getTweetsCounter,
          incrementTweetsCounter: incrementTweetsCounter,
        ),
      ),
    );
  }
}

/// Resolves the active account's profile, then hands it to [builder]: both
/// account-timeline tabs need the profile only to render their tweet cards
/// (screen name, sensitive check), not as a filter.
class _ActiveAccountFeed extends StatefulWidget {
  final Widget Function(UserWithExtra user) builder;

  const _ActiveAccountFeed({required this.builder});

  @override
  State<_ActiveAccountFeed> createState() => _ActiveAccountFeedState();
}

class _ActiveAccountFeedState extends State<_ActiveAccountFeed> with AutomaticKeepAliveClientMixin<_ActiveAccountFeed> {
  late Future<UserWithExtra?> _user;

  @override
  void initState() {
    super.initState();
    _user = _loadUser();
  }

  @override
  bool get wantKeepAlive => true;

  Future<UserWithExtra?> _loadUser() async {
    final active = await getActiveAccount();
    final screenName = active?.screenName;
    if (screenName == null) return null;

    final profile = await Twitter.getProfileByScreenName(screenName);
    return profile.user;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<UserWithExtra?>(
      future: _user,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return FullPageErrorWidget(
            error: snapshot.error,
            stackTrace: null,
            prefix: L10n.current.unable_to_load_the_tweets,
            onRetry: () => setState(() => _user = _loadUser()),
          );
        }

        final user = snapshot.data;
        if (user == null) {
          return _EmptyLikes(message: L10n.of(context).no_account_available_title);
        }

        return widget.builder(user);
      },
    );
  }
}
