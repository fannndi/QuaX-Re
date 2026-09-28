import 'package:material_ui/material_ui.dart';
import 'package:quax/cached/cached_tweets_model.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/tweet/paginated_tweet_list.dart';
import 'package:quax/tweet/tweet_context_scope.dart';
import 'package:quax/ui/errors.dart';

/// The Offline tab: every chain the For You and Following feeds have loaded,
/// replayed from the local archive. Two sub-tabs mirror the home's tabs, and
/// each can be cleared on its own — the archive grows without a limit until
/// the reader empties it.
class CachedScreen extends StatefulWidget {
  final ScrollController? scrollController;

  const CachedScreen({super.key, this.scrollController});

  @override
  State<CachedScreen> createState() => _CachedScreenState();
}

class _CachedScreenState extends State<CachedScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 2,
    vsync: this,
  );
  final CachedTweetModel _model = CachedTweetModel();

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
              Tab(text: L10n.of(context).foryou),
              Tab(text: L10n.of(context).following),
            ],
          ),
          actions: [
            AnimatedBuilder(
              animation: _tabController,
              builder: (context, _) => IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: L10n.of(context).clear_cached_posts,
                onPressed: _confirmClear,
              ),
            ),
          ],
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            _CachedFeed(
              source: CachedFeedSource.foryou,
              model: _model,
              scrollController: widget.scrollController,
              username: 'ForYou',
            ),
            _CachedFeed(
              source: CachedFeedSource.following,
              model: _model,
              scrollController: widget.scrollController,
              username: null,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClear() async {
    final source = CachedFeedSource.values[_tabController.index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L10n.of(context).clear_cached_posts),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(L10n.of(context).no),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(L10n.of(context).yes),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    await _model.clear(source);
    if (!mounted) return;
    showSnackBar(
      context,
      icon: '🧹',
      message: L10n.of(context).cached_posts_cleared,
    );
  }
}

class _CachedFeed extends StatefulWidget {
  final CachedFeedSource source;
  final CachedTweetModel model;
  final ScrollController? scrollController;
  final String? username;

  const _CachedFeed({
    required this.source,
    required this.model,
    required this.scrollController,
    required this.username,
  });

  @override
  State<_CachedFeed> createState() => _CachedFeedState();
}

class _CachedFeedState extends State<_CachedFeed>
    with AutomaticKeepAliveClientMixin<_CachedFeed> {
  late final TweetFeedController _feed = TweetFeedController();

  @override
  bool get wantKeepAlive => true;

  Future<TweetPageResult> _loadPage(String? cursor) {
    return widget.model.loadPage(source: widget.source, cursor: cursor);
  }

  @override
  void initState() {
    super.initState();
    // A clear from the app bar must empty this tab without a full rebuild.
    widget.model.revision.addListener(_onArchiveChanged);
  }

  void _onArchiveChanged() {
    if (!mounted) return;
    if (widget.model.revision.value != widget.source) return;
    // The archive is empty now: drop what is on screen and reload (which
    // answers the empty state).
    _feed.reset();
  }

  @override
  void dispose() {
    widget.model.revision.removeListener(_onArchiveChanged);
    _feed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return PaginatedTweetList(
      feed: _feed,
      loadPage: _loadPage,
      username: widget.username,
      firstPageErrorPrefix: L10n.of(context).unable_to_load_the_tweets,
      newPageErrorPrefix: L10n.of(context)
          .unable_to_load_the_next_page_of_tweets,
      emptyMessage: L10n.of(context).archive_empty,
    );
  }
}
