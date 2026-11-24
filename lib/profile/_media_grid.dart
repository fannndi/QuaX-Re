import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/profile/media_grid/media_grid.dart';
import 'package:quax/profile/media_grid/media_grid_items/media_grid_item.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/profile/profile_paging.dart';
import 'package:quax/tweet/tweet_load_counter.dart';
import 'package:quax/ui/errors.dart';
import 'package:quax/user.dart';
import 'package:quax/utils/paging.dart';

class ProfileMediaGrid extends StatefulWidget {
  final UserWithExtra user;

  /// `media` reads the video timeline, `photos` the photo grid: the web
  /// client split the old UserMedia endpoint into those two operations.
  final String mediaKind;

  const ProfileMediaGrid({
    super.key,
    required this.user,
    this.mediaKind = 'media',
  });

  @override
  State<ProfileMediaGrid> createState() => _ProfileMediaGridState();
}

class _ProfileMediaGridState extends State<ProfileMediaGrid> {
  late final CursorPagingController<String, MediaGridItem> _paging;

  static const int pageSize = 20;
  final _loadCounter = TweetLoadCounter();
  final _pageWindow = ProfilePageWindow<MediaGridItem>((item) => item.identity);

  @override
  void initState() {
    super.initState();
    _paging = CursorPagingController<String, MediaGridItem>(_fetchPage);
  }

  @override
  void dispose() {
    _pageWindow.invalidate();
    _paging.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    _pageWindow.invalidate();
    _paging.pagingController.refresh();
  }

  Future<CursorPage<String, MediaGridItem>> _fetchPage(String? cursor) async {
    final generation = _pageWindow.capture();
    final result = await Twitter.getTweets(
      widget.user.idStr!,
      widget.mediaKind,
      const [],
      cursor: cursor,
      count: pageSize,
      includeReplies: false,
      getTweetsCounter: _loadCounter.get,
      incrementTweetsCounter: _loadCounter.increment,
      resetTweetsCounter: _loadCounter.reset,
    );

    if (!_pageWindow.isCurrent(generation)) {
      return (items: const <MediaGridItem>[], nextCursor: null);
    }
    final page = mediaPageFromStatus(result, cursor);
    return (
      items: _pageWindow.apply(
        page.items,
        generation: generation,
        firstPage: cursor == null,
      ),
      nextCursor: page.nextCursor,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<TweetContextState>(
      builder: (context, model, child) {
        if (model.hideSensitive && (widget.user.possiblySensitive ?? false)) {
          return EmojiErrorWidget(
            emoji: '🍆🙈🍆',
            message: L10n.current.possibly_sensitive,
            errorMessage: L10n.current.possibly_sensitive_profile,
            onRetry: () async => model.setHideSensitive(false),
            retryText: L10n.current.yes_please,
          );
        }

        return MediaGrid(
          controller: _paging.pagingController,
          onRefresh: _refresh,
          firstPageErrorPrefix: L10n.of(context).unable_to_load_the_tweets,
          newPageErrorPrefix: L10n.of(context)
              .unable_to_load_the_next_page_of_tweets,
          emptyMessage: L10n.of(context).could_not_find_any_tweets_by_this_user,
        );
      },
    );
  }
}
