import 'dart:convert';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/client.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/profile/_likes.dart';
import 'package:quax/saved/liked_tweet_model.dart';
import 'package:quax/tweet/tweet.dart';
import 'package:quax/tweet/tweet_context_scope.dart';
import 'package:quax/ui/errors.dart';
import 'package:quax/user.dart';

/// The Like tab: what was liked inside the app (local database) next to the
/// real likes X holds for the active account. Two tabs, mirroring the feed's
/// For You / Following switch.
class LikesScreen extends StatefulWidget {
  final ScrollController scrollController;

  const LikesScreen({super.key, required this.scrollController});

  @override
  State<LikesScreen> createState() => _LikesScreenState();
}

class _LikesScreenState extends State<LikesScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(length: 2, vsync: this);

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
              Tab(text: L10n.of(context).profile),
            ],
          ),
          actions: [
            AnimatedBuilder(
              animation: _tabController,
              builder: (context, _) => _tabController.index == 0
                  ? IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: L10n.of(context).refresh,
                      onPressed: () => context.read<LikedTweetModel>().refreshLikedTweets(),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            _LocalLikes(scrollController: widget.scrollController),
            const _ProfileLikes(),
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
      onLoading: (_) => const Center(child: CircularProgressIndicator()),
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
class _ProfileLikes extends StatefulWidget {
  const _ProfileLikes();

  @override
  State<_ProfileLikes> createState() => _ProfileLikesState();
}

class _ProfileLikesState extends State<_ProfileLikes> with AutomaticKeepAliveClientMixin<_ProfileLikes> {
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

        return ProfileLikes(user: user);
      },
    );
  }
}

class SavedTweetTile extends StatelessWidget {
  final String id;
  final String? content;

  const SavedTweetTile({super.key, required this.id, this.content});

  @override
  Widget build(BuildContext context) {
    var content = this.content;
    if (content == null) {
      // The tweet is probably too big to fit inside the cursor and has been removed from the result set
      return SavedTweetTooLarge(id: id);
    }

    var tweet = TweetWithCard.fromJson(jsonDecode(content));

    return TweetTile(key: Key(tweet.idStr!), tweet: tweet, clickable: true);
  }
}

class SavedTweetTooLarge extends StatelessWidget {
  final String id;

  const SavedTweetTooLarge({super.key, required this.id});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading:
                  Icon(Icons.error_outline, color: Colors.red.harmonizeWith(Theme.of(context).colorScheme.primary)),
              title: Text(L10n.current.oops_something_went_wrong),
              subtitle: Text(L10n.current.saved_tweet_too_large),
            ),
          ],
        ),
      ),
    );
  }
}
