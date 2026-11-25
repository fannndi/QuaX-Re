import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:quax/app/design_tokens.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/search/search_media_grid.dart';
import 'package:quax/search/search_model.dart';
import 'package:quax/ui/app_bars.dart';
import 'package:quax/ui/app_states.dart';
import 'package:quax/tweet/paginated_tweet_list.dart';
import 'package:quax/tweet/tweet_context_scope.dart';
import 'package:quax/ui/errors.dart';
import 'package:quax/user.dart';
import 'package:quax/utils/paging.dart';

class SearchArguments {
  final int initialTab;
  final String? query;

  SearchArguments(this.initialTab, {this.query});
}

class ResultsScreen extends StatelessWidget {
  const ResultsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final arguments =
        ModalRoute.of(context)!.settings.arguments as SearchArguments;

    return _ResultsScreen(
      initialTab: arguments.initialTab,
      query: arguments.query,
    );
  }
}

class _ResultsScreen extends StatefulWidget {
  final int initialTab;
  final String? query;

  const _ResultsScreen({required this.initialTab, this.query});

  @override
  State<_ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<_ResultsScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  late final TabController _tabController;
  late final SearchTweetsPagination _topTweets;
  late final SearchTweetsPagination _latestTweets;
  late final SearchMediaPagination _mediaResults;
  late final SearchUsersPagination _userResults;

  Timer? _debounce;
  String? _lastDispatchedQuery;

  @override
  void initState() {
    super.initState();

    _tabController = TabController(
      length: 4,
      vsync: this,
      initialIndex: widget.initialTab,
    );

    final initialQuery = widget.query ?? '';
    _topTweets = SearchTweetsPagination(
      product: 'Top',
      initialQuery: initialQuery,
    );
    _latestTweets = SearchTweetsPagination(
      product: 'Latest',
      initialQuery: initialQuery,
    );
    _mediaResults = SearchMediaPagination(initialQuery: initialQuery);
    _userResults = SearchUsersPagination(initialQuery: initialQuery);

    _queryController.text = initialQuery;
    _lastDispatchedQuery = initialQuery;
    _queryController.addListener(_onQueryChanged);

    // The user pager fetches its first page when its PagedListView mounts.
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
    _userResults.dispose();
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
    _userResults.updateQuery(query);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Needed as we're nesting Scaffolds, which causes Flutter to calculate keyboard height incorrectly
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: L10n.of(context).back,
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: AppSpace.lg),
          child: SearchBar(
            controller: _queryController,
            focusNode: _focusNode,
            hintText: L10n.of(context).search,
            textInputAction: TextInputAction.search,
            leading: const Icon(Icons.search, size: AppSize.icon),
            trailing: [
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _queryController,
                builder: (context, value, _) {
                  if (value.text.isEmpty) return const SizedBox.shrink();
                  return IconButton(
                    icon: const Icon(Icons.close, size: AppSize.icon),
                    tooltip: L10n.of(context).close,
                    onPressed: _queryController.clear,
                  );
                },
              ),
            ],
          ),
        ),
        shape: appBarBorder(context),
        bottom: TabBar(
          controller: _tabController,
          labelPadding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
          tabs: [
            Tab(text: L10n.of(context).search_top),
            Tab(text: L10n.of(context).search_latest),
            Tab(text: L10n.of(context).media),
            Tab(text: L10n.of(context).search_people),
          ],
        ),
      ),
      body: TweetContextScope(
        child: TabBarView(
          controller: _tabController,
          children: [
            PaginatedTweetList(
              feed: _topTweets.feed,
              loadPage: _topTweets.loadPage,
              username: null,
              firstPageErrorPrefix: L10n.of(context)
                  .unable_to_load_the_search_results,
              newPageErrorPrefix: L10n.of(context)
                  .unable_to_load_the_next_page_of_tweets,
              emptyMessage: L10n.of(context).no_results,
              emptyIcon: Icons.search_off,
            ),
            PaginatedTweetList(
              feed: _latestTweets.feed,
              loadPage: _latestTweets.loadPage,
              username: null,
              firstPageErrorPrefix: L10n.of(context)
                  .unable_to_load_the_search_results,
              newPageErrorPrefix: L10n.of(context)
                  .unable_to_load_the_next_page_of_tweets,
              emptyMessage: L10n.of(context).no_results,
              emptyIcon: Icons.search_off,
            ),
            SearchMediaGrid(model: _mediaResults),
            _UserSearchResultList(pagination: _userResults),
          ],
        ),
      ),
    );
  }
}

class _UserSearchResultList extends StatelessWidget {
  final SearchUsersPagination pagination;

  const _UserSearchResultList({required this.pagination});

  @override
  Widget build(BuildContext context) {
    return PagingListener<int, UserWithExtra>(
      controller: pagination.pagingController,
      builder: (context, state, fetchNextPage) =>
          PagedListView<int, UserWithExtra>(
            padding: EdgeInsets.only(
              bottom: MediaQuery.paddingOf(context).bottom,
            ),
            state: state,
            fetchNextPage: fetchNextPage,
            builderDelegate: PagedChildBuilderDelegate<UserWithExtra>(
              invisibleItemsThreshold: 8,
              firstPageProgressIndicatorBuilder: (context) =>
                  const Center(child: CircularProgressIndicator()),
              itemBuilder: (context, user, index) => UserTile(user: user),
              firstPageErrorIndicatorBuilder: (context) => FullPageErrorWidget(
                error: pagingErrorOf(state)?.error,
                stackTrace: pagingErrorOf(state)?.stackTrace,
                prefix: L10n.of(context).unable_to_load_the_search_results,
                onRetry: fetchNextPage,
              ),
              newPageErrorIndicatorBuilder: (context) => FullPageErrorWidget(
                error: pagingErrorOf(state)?.error,
                stackTrace: pagingErrorOf(state)?.stackTrace,
                prefix: L10n.of(context).unable_to_load_the_next_page_of_tweets,
                onRetry: fetchNextPage,
              ),
              noItemsFoundIndicatorBuilder: (context) => AppEmptyState(
                message: L10n.of(context).no_results,
                icon: Icons.search_off,
              ),
            ),
          ),
    );
  }
}
