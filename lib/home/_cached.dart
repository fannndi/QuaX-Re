import 'package:material_ui/material_ui.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/tweet/conversation.dart';
import 'package:quax/tweet/tweet_context_scope.dart';
import 'package:quax/utils/timeline_cache.dart';
import 'package:quax/utils/tweet_cache_index.dart';

/// Nudges the shelf to re-read the disk (tab re-tap).
final ValueNotifier<int> cachedFeedRevision = ValueNotifier<int>(0);

/// The offline shelf: the For You and Following first pages stored while the
/// live feeds fetched. Home stays fresh; this tab is what is readable without
/// a connection, complete with the media URLs and thumbnails of each post.
class CachedTweets extends StatefulWidget {
  const CachedTweets({super.key});

  @override
  State<CachedTweets> createState() => _CachedTweetsState();
}

class _CachedTweetsState extends State<CachedTweets> {
  bool _loading = true;
  List<TweetChain> _forYou = const [];
  List<TweetChain> _following = const [];

  @override
  void initState() {
    super.initState();
    _load();
    TweetCacheIndex().revision.addListener(_load);
    cachedFeedRevision.addListener(_load);
  }

  @override
  void dispose() {
    TweetCacheIndex().revision.removeListener(_load);
    cachedFeedRevision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final bodies = await Future.wait([
      TimelineCache.read(TimelineCache.keyFor('foryou')),
      TimelineCache.read(TimelineCache.keyFor('following')),
    ]);
    if (!mounted) return;

    setState(() {
      _forYou = _parse(bodies[0], Twitter.previewForYouTweets);
      _following = _parse(bodies[1], Twitter.previewFollowingTweets);
      _loading = false;
    });
  }

  List<TweetChain> _parse(String? body, TweetStatus Function(String) parser) {
    if (body == null) return const [];
    try {
      return parser(body).chains;
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_forYou.isEmpty && _following.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(L10n.of(context).no_cached_posts, textAlign: TextAlign.center),
        ),
      );
    }

    return TweetContextScope(
      child: ListView(
        padding: EdgeInsets.only(top: 4, bottom: MediaQuery.of(context).padding.bottom),
        children: [
          if (_forYou.isNotEmpty) ...[
            _sectionHeader(context, L10n.of(context).foryou),
            for (final chain in _forYou)
              TweetConversation(id: chain.id, tweets: chain.tweets, username: null, isPinned: chain.isPinned),
          ],
          if (_following.isNotEmpty) ...[
            _sectionHeader(context, L10n.of(context).following),
            for (final chain in _following)
              TweetConversation(id: chain.id, tweets: chain.tweets, username: null, isPinned: chain.isPinned),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}
