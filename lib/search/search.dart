import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:quax/constants.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/library/library_model.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/saved/saved_tweet_tile.dart';
import 'package:quax/search/local_search_model.dart';
import 'package:quax/search/search_media_grid.dart';
import 'package:quax/search/search_model.dart';
import 'package:quax/tweet/_video.dart';
import 'package:quax/tweet/paginated_tweet_list.dart';
import 'package:quax/ui/errors.dart';
import 'package:quax/ui/skeletons.dart';
import 'package:quax/user.dart';
import 'package:quax/utils/image_decode.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';

class SearchArguments {
  final int initialTab;
  final String? query;
  final bool focusInputOnOpen;

  SearchArguments(this.initialTab, {this.query, this.focusInputOnOpen = false});
}

class ResultsScreen extends StatelessWidget {
  const ResultsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final arguments = ModalRoute.of(context)!.settings.arguments as SearchArguments;

    return _ResultsScreen(
        initialTab: arguments.initialTab, query: arguments.query, focusInputOnOpen: arguments.focusInputOnOpen);
  }
}

class _ResultsScreen extends StatefulWidget {
  final int initialTab;
  final String? query;
  final bool focusInputOnOpen;

  const _ResultsScreen({required this.initialTab, this.query, this.focusInputOnOpen = false});

  @override
  State<_ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<_ResultsScreen> with SingleTickerProviderStateMixin {
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  late final TabController _tabController;
  late final SearchTweetsPagination _topTweets;
  late final SearchTweetsPagination _latestTweets;
  late final SearchMediaPagination _mediaResults;
  late final SearchUsersModel _searchUsersModel;
  late final LocalSearchModel _localSearchModel;

  Timer? _debounce;
  String? _lastDispatchedQuery;

  @override
  void initState() {
    super.initState();

    _tabController = TabController(length: 5, vsync: this, initialIndex: widget.initialTab);

    final initialQuery = widget.query ?? '';
    _topTweets = SearchTweetsPagination(product: 'Top', initialQuery: initialQuery);
    _latestTweets = SearchTweetsPagination(product: 'Latest', initialQuery: initialQuery);
    _mediaResults = SearchMediaPagination(initialQuery: initialQuery);
    _searchUsersModel = SearchUsersModel();
    _localSearchModel = LocalSearchModel(PrefService.of(context, listen: false));

    _queryController.text = initialQuery;
    _lastDispatchedQuery = initialQuery;
    _queryController.addListener(_onQueryChanged);

    // TODO: Focussing makes the selection go to the start?!

    // The tweet tabs' first-page requests are fired automatically by their
    // PagedListViews using the initial query above; the user-search Store
    // needs an explicit kick.
    if (initialQuery.isNotEmpty) {
      _searchUsersModel.searchUsers(initialQuery, context);
      _localSearchModel.search(initialQuery);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryController.dispose();
    _focusNode.dispose();
    _tabController.dispose();
    _topTweets.dispose();
    _latestTweets.dispose();
    _mediaResults.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    if (_queryController.text == _lastDispatchedQuery) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 750), _dispatchQuery);
  }

  void _dispatchQuery() {
    if (!mounted) return;
    final query = _queryController.text;
    _lastDispatchedQuery = query;
    _topTweets.updateQuery(query);
    _latestTweets.updateQuery(query);
    _mediaResults.updateQuery(query);
    _searchUsersModel.searchUsers(query, context);
    _localSearchModel.search(query);
  }

  @override
  Widget build(BuildContext context) {
    var prefs = PrefService.of(context, listen: false);

    return Scaffold(
      // Needed as we're nesting Scaffolds, which causes Flutter to calculate keyboard height incorrectly
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        flexibleSpace: Padding(
          padding: EdgeInsets.fromLTRB(8, 36, 8, 8),
          child: SearchBar(
            controller: _queryController,
            focusNode: _focusNode,
            textInputAction: TextInputAction.search,
            leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context)),
            trailing: [
              FollowButton(user: SearchSubscription(id: _queryController.text, createdAt: DateTime.now())),
            ],
          ),
        ),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.trending_up)),
            Tab(icon: Icon(Icons.access_time_outlined)),
            Tab(icon: Icon(Icons.image)),
            Tab(icon: Icon(Icons.person_search)),
            Tab(icon: Icon(Icons.saved_search)),
          ],
          labelColor: Theme.of(context).appBarTheme.foregroundColor,
          indicatorColor: Theme.of(context).appBarTheme.foregroundColor,
          dividerColor: Theme.of(context).colorScheme.surfaceBright.withAlpha(150),
        ),
      ),
      body: MultiProvider(
        providers: [
          ChangeNotifierProvider<TweetContextState>(
              create: (_) => TweetContextState(prefs.get(optionTweetsHideSensitive))),
          ChangeNotifierProvider<VideoContextState>(
              create: (_) => VideoContextState(prefs.get(optionMediaDefaultMute))),
        ],
        child: TabBarView(
          controller: _tabController,
          children: [
            PaginatedTweetList(
              feed: _topTweets.feed,
              loadPage: _topTweets.loadPage,
              username: null,
              firstPageErrorPrefix: L10n.of(context).unable_to_load_the_search_results,
              newPageErrorPrefix: L10n.of(context).unable_to_load_the_next_page_of_tweets,
              emptyMessage: L10n.of(context).no_results,
            ),
            PaginatedTweetList(
              feed: _latestTweets.feed,
              loadPage: _latestTweets.loadPage,
              username: null,
              firstPageErrorPrefix: L10n.of(context).unable_to_load_the_search_results,
              newPageErrorPrefix: L10n.of(context).unable_to_load_the_next_page_of_tweets,
              emptyMessage: L10n.of(context).no_results,
            ),
            SearchMediaGrid(model: _mediaResults),
            _UserSearchResultList(store: _searchUsersModel, onRetry: _dispatchQuery),
            _LocalSearchResultList(model: _localSearchModel, onRetry: _dispatchQuery),
          ],
        ),
      ),
    );
  }
}

class _UserSearchResultList extends StatelessWidget {
  final SearchUsersModel store;
  final VoidCallback onRetry;

  const _UserSearchResultList({required this.store, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ScopedBuilder<SearchUsersModel, List<UserWithExtra>>.transition(
      store: store,
      onLoading: (_) => const Center(child: CircularProgressIndicator()),
      onError: (_, error) => FullPageErrorWidget(
        error: error,
        stackTrace: null,
        prefix: L10n.of(context).unable_to_load_the_search_results,
        onRetry: onRetry,
      ),
      onState: (_, items) {
        if (items.isEmpty) {
          return Center(child: Text(L10n.of(context).no_results));
        }
        return ListView.builder(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
          itemCount: items.length,
          itemBuilder: (context, index) {
            return UserTile(user: UserSubscription.fromUser(items[index]));
          },
        );
      },
    );
  }
}

/// Offline results: posts from the local database rendered as regular cards,
/// then the downloaded media whose file name matches.
class _LocalSearchResultList extends StatelessWidget {
  final LocalSearchModel model;
  final VoidCallback onRetry;

  const _LocalSearchResultList({required this.model, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ScopedBuilder<LocalSearchModel, List<LocalSearchHit>>.transition(
      store: model,
      onLoading: (_) => const TweetListSkeleton(),
      onError: (_, error) => FullPageErrorWidget(
        error: error,
        stackTrace: null,
        prefix: L10n.of(context).unable_to_load_the_search_results,
        onRetry: onRetry,
      ),
      onState: (_, hits) {
        if (model.query.trim().isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(L10n.of(context).local_search_hint, textAlign: TextAlign.center),
            ),
          );
        }
        if (hits.isEmpty) {
          return Center(child: Text(L10n.of(context).no_results));
        }

        final posts = hits.whereType<LocalPostHit>().toList();
        final media = hits.whereType<LocalMediaHit>().toList();

        return ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
          itemCount: posts.length + (media.isEmpty ? 0 : media.length + 1),
          itemBuilder: (context, index) {
            if (index < posts.length) {
              final post = posts[index].post;
              return SavedTweetTile(id: post.id, content: post.content);
            }

            final mediaIndex = index - posts.length - 1;
            if (mediaIndex < 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                child: Text(L10n.of(context).library, style: Theme.of(context).textTheme.titleSmall),
              );
            }
            return _LocalMediaTile(model: model, entry: media[mediaIndex].entry);
          },
        );
      },
    );
  }
}

class _LocalMediaTile extends StatelessWidget {
  final LocalSearchModel model;
  final LibraryEntry entry;

  const _LocalMediaTile({required this.model, required this.entry});

  @override
  Widget build(BuildContext context) {
    final decodeWidth = decodeWidthFor(context, 48);

    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 48,
          height: 48,
          child: entry.isVideo ? _buildVideoThumb(decodeWidth) : _buildImageThumb(decodeWidth),
        ),
      ),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${entry.sizeMb.toStringAsFixed(1)} MB'),
      trailing: const Icon(Icons.open_in_new),
      onTap: () async {
        final opened = await model.openExternally(entry.file.path);
        if (!opened && context.mounted) {
          showSnackBar(context, icon: '🙊', message: L10n.of(context).oops_something_went_wrong);
        }
      },
    );
  }

  Widget _buildImageThumb(int decodeWidth) {
    return Image.file(
      entry.file,
      fit: BoxFit.cover,
      cacheWidth: decodeWidth,
      errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
    );
  }

  Widget _buildVideoThumb(int decodeWidth) {
    return FutureBuilder<String?>(
      future: model.thumbnailFor(entry),
      builder: (context, snapshot) {
        final thumbPath = snapshot.data;
        if (thumbPath == null) {
          return const ColoredBox(
            color: Colors.black26,
            child: Center(child: Icon(Icons.play_circle_outline)),
          );
        }
        return Image.file(
          File(thumbPath),
          fit: BoxFit.cover,
          cacheWidth: decodeWidth,
          errorBuilder: (_, _, _) => const Icon(Icons.play_circle_outline),
        );
      },
    );
  }
}
