import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/group/feed_refresh_controller.dart';
import 'package:quax/tweet/cached_tweet_list.dart';
import 'package:quax/tweet/conversation.dart';
import 'package:quax/ui/errors.dart';
import 'package:quax/ui/skeletons.dart';
import 'package:quax/utils/network_status.dart';
import 'package:quax/utils/paging.dart';
import 'package:quax/utils/tweet_freshness_index.dart';

typedef TweetPageResult = ({List<TweetChain> chains, String? nextCursor});
typedef TweetPageLoader = Future<TweetPageResult> Function(String? cursor);

/// Owns a [CursorPagingController] for cursor-paginated tweet chains, bridging
/// it onto the app's `(chains, nextCursor)` loaders.
///
/// v5 bakes the fetch callback into the controller at construction, yet several
/// feeds create the controller away from the loader (and cache it across widget
/// remounts — see [FeedSessionCache]). So the loader lives in a rebindable field
/// that [PaginatedTweetList] sets on mount.
class TweetFeedController {
  late final CursorPagingController<String, TweetChain> _paging;
  TweetPageLoader? _loader;

  /// Chronological feeds (Following) merge a refreshed first page on top of
  /// what is already loaded; a refresh must never shorten the feed to just the
  /// handful of newer posts.
  final bool mergeOnRefresh;

  TweetFeedController({this.mergeOnRefresh = false}) {
    _paging = CursorPagingController<String, TweetChain>(_fetch);
  }

  PagingController<int, TweetChain> get controller => _paging.pagingController;

  set loader(TweetPageLoader loader) => _loader = loader;

  bool get hasItems => _paging.items != null;

  List<TweetChain>? get items => _paging.items;

  Future<CursorPage<String, TweetChain>> _fetch(String? cursor) async {
    final result = await _loader!(cursor);
    final next = result.nextCursor;
    return (items: _dedupe(result.chains, cursor), nextCursor: _isLastPage(result.chains, next, cursor) ? null : next);
  }

  // Ranked feeds can repeat a tweet across pages; a repeated chain would render
  // twice, so anything already on screen is dropped from later pages. The raw
  // page decides "last page" above, so an all-duplicate page doesn't end
  // pagination early.
  List<TweetChain> _dedupe(List<TweetChain> chains, String? cursor) {
    if (cursor == null) return chains;

    final seen = (_paging.items ?? const <TweetChain>[]).map((chain) => chain.id).toSet();
    final fresh = <TweetChain>[];
    for (final chain in chains) {
      if (seen.add(chain.id)) fresh.add(chain);
    }
    return fresh;
  }

  // Pagination ends on an empty page, a missing/blank cursor, or a cursor that
  // didn't advance (which would otherwise loop forever).
  bool _isLastPage(List<TweetChain> chains, String? next, String? cursor) =>
      chains.isEmpty || next == null || next.isEmpty || next == cursor;

  /// Fetches the first page without touching the visible list, so the caller
  /// can decide between replacing the items or holding them behind a "new
  /// posts" pill.
  Future<TweetPageResult> fetchFirstPage() => _loader!(null);

  /// Puts a fetched first page in place without the first-page spinner.
  ///
  /// Two safety rules, because X serves empty and partial first pages all the
  /// time (a quiet "latest" feed answers empty, a refresh with `seenTweetIds`
  /// only answers what is new):
  /// - an empty page never wipes a non-empty list — that must not read as a
  ///   broken tab;
  /// - when [mergeOnRefresh] is set, the page is prepended to the visible
  ///   items (deduplicated) instead of replacing them.
  ///
  /// Returns whether anything was actually applied.
  bool applyFirstPage(TweetPageResult result) {
    final current = _paging.items;
    final hasCurrent = current?.isNotEmpty ?? false;
    if (result.chains.isEmpty && hasCurrent) return false;

    final next = result.nextCursor;
    final isLast = _isLastPage(result.chains, next, null);
    final cursor = isLast ? null : next;

    if (mergeOnRefresh && hasCurrent) {
      final freshIds = result.chains.map((chain) => chain.id).toSet();
      final merged = <TweetChain>[
        ...result.chains,
        ...current!.where((chain) => !freshIds.contains(chain.id)),
      ];
      _paging.replaceFirstPage(merged, cursor);
      return true;
    }

    _paging.replaceFirstPage(result.chains, cursor);
    return result.chains.isNotEmpty;
  }

  void setError(Object error, StackTrace stackTrace) => _paging.setError(error, stackTrace);

  /// Reloads the first page and replaces the items in place, *without* resetting
  /// to the first-page spinner the way [PagingController.refresh] does. Used by
  /// pull-to-refresh so the existing tweets stay visible under the indicator.
  Future<void> softRefresh() async {
    try {
      applyFirstPage(await fetchFirstPage());
    } catch (e, stackTrace) {
      setError(e, stackTrace);
    }
  }

  /// Drops what is loaded and reloads the first page from scratch.
  ///
  /// Used when the data underneath the feed changed (the active account
  /// switched): a refresh would *merge* on the chronological feeds and keep
  /// the previous login's posts — and its pagination cursor — under the new
  /// ones. This clears both, and any page still in flight is cancelled, so a
  /// response fetched for the previous account cannot land in the new list.
  void reset() => _paging.reset();

  void dispose() => _paging.dispose();
}

/// Shared paginated tweet list used by the For-you feed, the group feed and
/// the tweet search results. Drives a [TweetFeedController]'s v5 controller
/// through the standard `PagedListView` shell with error / empty widgets.
///
/// The controller's lifecycle (creation, disposal, cross-mount caching) stays
/// at the call site — this widget only binds the loader and, while a cached
/// preview is shown, kicks off the first page itself.
class PaginatedTweetList extends StatefulWidget {
  final TweetFeedController feed;
  final TweetPageLoader loadPage;
  final String? username;
  final Future<void> Function()? onRefresh;
  final String firstPageErrorPrefix;
  final String newPageErrorPrefix;
  final String emptyMessage;
  // Cached tweets shown in place of the first-page spinner while the initial
  // load is in flight, so a feed reveals its cached content instead of a
  // full-screen progress indicator.
  final List<TweetChain>? firstPagePreview;
  // Remembers the scroll offset across app restarts, per feed.
  final String? scrollKey;

  const PaginatedTweetList({
    super.key,
    required this.feed,
    required this.loadPage,
    required this.username,
    required this.firstPageErrorPrefix,
    required this.newPageErrorPrefix,
    required this.emptyMessage,
    this.onRefresh,
    this.firstPagePreview,
    this.scrollKey,
  });

  @override
  State<PaginatedTweetList> createState() => _PaginatedTweetListState();
}

class _PaginatedTweetListState extends State<PaginatedTweetList> with WidgetsBindingObserver {
  final GlobalKey<RefreshIndicatorState> _refreshKey = GlobalKey<RefreshIndicatorState>();
  final ScrollController _scrollController = ScrollController();
  FeedRefreshController? _refreshController;
  bool _firstLoadStarted = false;
  bool _pendingInitialLoad = false;
  bool _onlineListenerAttached = false;

  // Freshness: coming back to the app after a while quietly refreshes the
  // timeline, so what the reader sees is current without a manual pull.
  DateTime _lastLoadedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _staleAfter = Duration(minutes: 2);

  // A restored scroll position older than this is skipped: opening the app at
  // yesterday's tweets reads as a broken feed, so it starts fresh at the top.
  static const _scrollRestoreMaxAge = Duration(minutes: 30);

  // The "new posts" pill: a fetched first page held back while the reader is
  // scrolled down, so fresh tweets never yank the list under them.
  static const _pillThreshold = 500.0;
  bool _newPostsAvailable = false;
  TweetPageResult? _pendingFirstPage;

  // Scroll memory: the offset is persisted (debounced) and restored once the
  // first page is in place.
  bool _scrollRestored = false;
  Timer? _scrollSaveTimer;

  PagingController<int, TweetChain> get _controller => widget.feed.controller;

  @override
  void initState() {
    super.initState();
    widget.feed.loader = widget.loadPage;
    // While we show the cached preview the PagedListView isn't mounted, so it
    // can't trigger the first page itself — we rebuild to swap it in once items
    // arrive, so listen for that.
    _controller.addListener(_onControllerChanged);
    _scrollController.addListener(_onScroll);
    // Offline mode: the moment the connection returns, retry the page that
    // failed (or that we deliberately did not attempt).
    _attachOnlineListener();
    NetworkStatus().check();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Only feeds that support pull-to-refresh expose their refresh to the
    // app-bar button. Outside a GroupFeedShell there is no controller to bind.
    if (widget.onRefresh == null) return;
    FeedRefreshController? controller;
    try {
      controller = context.read<FeedRefreshController>();
    } on ProviderNotFoundException {
      controller = null;
    }
    if (!identical(controller, _refreshController)) {
      _refreshController?.unregister(_showRefresh);
      _refreshController = controller;
      _refreshController?.register(_showRefresh);
    }
  }

  @override
  void didUpdateWidget(PaginatedTweetList oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.feed.loader = widget.loadPage;
    if (!identical(oldWidget.feed, widget.feed)) {
      oldWidget.feed.controller.removeListener(_onControllerChanged);
      _controller.addListener(_onControllerChanged);
      // A fresh feed may need its first page kicked off again from the preview.
      _firstLoadStarted = false;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _scrollSaveTimer?.cancel();
    _refreshController?.unregister(_showRefresh);
    if (_onlineListenerAttached) {
      NetworkStatus().online.removeListener(_onOnlineChanged);
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!NetworkStatus().online.value) return;

    final items = _controller.value.items;
    if (items == null || items.isEmpty) return;
    if (DateTime.now().difference(_lastLoadedAt) < _staleAfter) return;

    // Drive the visible pull-to-refresh spinner, so the automatic fetch reads
    // as "loading for a moment" instead of happening invisibly.
    final indicator = _refreshKey.currentState;
    if (indicator != null && widget.onRefresh != null) {
      indicator.show();
    } else {
      _handleRefresh();
    }
  }

  void _attachOnlineListener() {
    if (_onlineListenerAttached) return;
    _onlineListenerAttached = true;
    NetworkStatus().online.addListener(_onOnlineChanged);
  }

  void _onOnlineChanged() {
    if (!mounted || !NetworkStatus().online.value) return;
    // The connection is back: retry whatever offline mode held back.
    _firstLoadStarted = false;
    setState(() {});
    _maybeStartFirstLoad();
    if (_controller.value.error != null && _controller.value.items == null) {
      _controller.fetchNextPage();
    }
  }

  /// Shown when there is genuinely nothing to display while offline: neither
  /// live items, nor an error from a real attempt, nor a cached preview.
  Widget _buildOffline(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48),
            const SizedBox(height: 12),
            Text(L10n.of(context).offline_message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () => NetworkStatus().check(force: true),
              icon: const Icon(Icons.refresh),
              label: Text(L10n.of(context).retry),
            ),
          ],
        ),
      ),
    );
  }

  void _onControllerChanged() {
    if (_controller.value.items?.isNotEmpty ?? false) {
      _lastLoadedAt = DateTime.now();
    }
    if (mounted) setState(() {});
  }

  // Drives the same RefreshIndicator the user pulls down, so the app-bar refresh
  // button shows the top spinner and runs the soft refresh identically.
  Future<void> _showRefresh() async {
    await _refreshKey.currentState?.show();
  }

  Widget _buildChain(BuildContext context, TweetChain chain) => TweetConversation(
        // Keyed by chain: refreshed pages shift indices, and without the key a
        // recycled element would keep rendering the tweet it held before.
        key: ValueKey(chain.id),
        id: chain.id,
        tweets: chain.tweets,
        username: widget.username,
        isPinned: chain.isPinned,
      );

  /// Soft refresh used by the pull-to-refresh gesture. Runs the caller's
  /// [onRefresh] side effects, then reloads the first page. Scrolled down with
  /// genuinely new posts on top, the page is held behind the pill instead.
  Future<void> _handleRefresh() async {
    await widget.onRefresh?.call();
    if (!mounted) return;

    final before = _currentTopId();
    try {
      final result = await widget.feed.fetchFirstPage();
      if (!mounted) return;

      final after = result.chains.isEmpty ? null : result.chains.first.id;
      final scrolledDown = _scrollController.hasClients && _scrollController.offset > _pillThreshold;
      if (before != null && after != null && before != after && scrolledDown) {
        _pendingFirstPage = result;
        setState(() => _newPostsAvailable = true);
        return;
      }

      final applied = widget.feed.applyFirstPage(result);
      // A reload closes the freshness round: what just loaded becomes Old and
      // only arrivals after this point read as New. An empty page changed
      // nothing, so the round stays open.
      if (applied) {
        TweetFreshnessIndex().promoteSeenToBaseline();
      }
    } catch (e, stackTrace) {
      // A failed refresh must not look like "nothing new": say so.
      widget.feed.setError(e, stackTrace);
      if (mounted) {
        showSnackBar(context, icon: '🙊', message: e.toString());
      }
    }
  }

  String? _currentTopId() {
    final items = _controller.value.items;
    return (items == null || items.isEmpty) ? null : items.first.id;
  }

  void _onScroll() {
    _scheduleScrollSave();

    if (!_newPostsAvailable || !_scrollController.hasClients) return;
    if (_scrollController.offset > 40) return;

    // Back at the top: slide the held page in and drop the pill.
    final pending = _pendingFirstPage;
    _pendingFirstPage = null;
    if (pending != null) widget.feed.applyFirstPage(pending);
    setState(() => _newPostsAvailable = false);
  }

  Future<void> _jumpToNewPosts() async {
    final pending = _pendingFirstPage;
    _pendingFirstPage = null;
    if (pending != null) widget.feed.applyFirstPage(pending);
    setState(() => _newPostsAvailable = false);

    if (_scrollController.hasClients) {
      await _scrollController.animateTo(0,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  void _scheduleScrollSave() {
    final key = widget.scrollKey;
    if (key == null || !_scrollController.hasClients) return;
    // One timer in flight is enough: it reads the offset when it fires, so the
    // final position always lands within the debounce window without a new
    // timer (and its garbage) on every scroll frame.
    if (_scrollSaveTimer?.isActive ?? false) return;

    _scrollSaveTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted || !_scrollController.hasClients) return;
      final prefs = PrefService.of(context, listen: false);
      prefs.set<double>('scroll.$key', _scrollController.offset);
      prefs.set<int>('scroll.$key.at', DateTime.now().millisecondsSinceEpoch);
    });
  }

  /// Jumps back to the last reading position once the first page is in place —
  /// unless that position is old, in which case the feed opens at the top with
  /// current content instead of yesterday's posts.
  void _maybeRestoreScroll() {
    final key = widget.scrollKey;
    if (_scrollRestored || key == null) return;

    final items = _controller.value.items;
    if (items == null || items.isEmpty || !_scrollController.hasClients) return;
    _scrollRestored = true;

    final prefs = PrefService.of(context, listen: false);
    final savedAt = prefs.get<int>('scroll.$key.at');
    final saved = prefs.get<double>('scroll.$key') ?? 0;
    if (saved <= 0) return;

    if (savedAt != null) {
      final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(savedAt));
      if (age > _scrollRestoreMaxAge) return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = saved.clamp(0.0, _scrollController.position.maxScrollExtent);
      if (target > 0) _scrollController.jumpTo(target);
    });
  }

  Widget _buildNewPostsPill() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 2,
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: _jumpToNewPosts,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_upward, size: 18, color: scheme.onSecondaryContainer),
              const SizedBox(width: 6),
              Text(L10n.of(context).new_posts,
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: scheme.onSecondaryContainer)),
            ],
          ),
        ),
      ),
    );
  }

  // True while we should display the cached preview: the first page hasn't
  // loaded yet, there's no error to surface, and we actually have cached tweets.
  bool get _showingPreview {
    final preview = widget.firstPagePreview;
    final state = _controller.value;
    return preview != null && preview.isNotEmpty && state.items == null && state.error == null;
  }

  // The PagedListView normally kicks off the first page when it mounts. While
  // the preview replaces it, nothing does — so trigger the load ourselves once.
  void _maybeStartFirstLoad() {
    if (_firstLoadStarted) return;
    final state = _controller.value;
    if (state.items != null || state.error != null) return;
    _firstLoadStarted = true;
    // Deferred: we're called from build() and fetchNextPage() mutates the
    // controller synchronously, which would setState() mid-build via our listener.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!NetworkStatus().online.value) {
        // Offline: keep whatever is on screen; the listener retries later.
        _firstLoadStarted = false;
        NetworkStatus().check();
        return;
      }
      if (widget.onRefresh == null) {
        _controller.fetchNextPage();
        return;
      }
      final refreshState = _refreshKey.currentState;
      if (refreshState != null) {
        _pendingInitialLoad = true;
        refreshState.show();
      } else {
        _controller.fetchNextPage();
      }
    });
  }

  Future<void> _onRefreshTriggered() async {
    if (_pendingInitialLoad) {
      _pendingInitialLoad = false;
      await widget.feed.softRefresh();
      return;
    }
    await _handleRefresh();
  }

  Widget _wrapWithRefresh(Widget child) {
    if (widget.onRefresh == null) return child;
    return RefreshIndicator(key: _refreshKey, onRefresh: _onRefreshTriggered, child: child);
  }

  @override
  Widget build(BuildContext context) {
    _maybeRestoreScroll();

    if (_showingPreview) {
      _maybeStartFirstLoad();
      return _wrapWithRefresh(CachedTweetList(widget.firstPagePreview!, username: widget.username));
    }

    final state = _controller.value;
    if (!NetworkStatus().online.value && state.items == null && state.error == null) {
      NetworkStatus().check();
      return _buildOffline(context);
    }

    final list = PagingListener<int, TweetChain>(
      controller: _controller,
      builder: (context, state, fetchNextPage) => PagedListView<int, TweetChain>(
        padding: EdgeInsets.only(top: 4, bottom: MediaQuery.of(context).padding.bottom),
        state: state,
        fetchNextPage: fetchNextPage,
        scrollController: _scrollController,
        addAutomaticKeepAlives: false,
        // Pre-build items further ahead of the viewport: heavy media cards need
        // decode time, and the default ~250px cache causes visible stutter.
        // 1200px also makes the pager fetch the next page a screen earlier.
        cacheExtent: 1200,
        builderDelegate: PagedChildBuilderDelegate(
          // Start fetching when this many chains are still below the viewport:
          // the next page arrives before the reader reaches the bottom, so a
          // long fling keeps rolling instead of stalling on the spinner.
          invisibleItemsThreshold: 8,
          itemBuilder: (context, chain, index) => _buildChain(context, chain),
          firstPageProgressIndicatorBuilder: (context) => const TweetListSkeleton(),
          firstPageErrorIndicatorBuilder: (context) => NetworkStatus().online.value
              ? FullPageErrorWidget(
                  error: pagingErrorOf(state)?.error,
                  stackTrace: pagingErrorOf(state)?.stackTrace,
                  prefix: widget.firstPageErrorPrefix,
                  onRetry: fetchNextPage,
                )
              : _buildOffline(context),
          newPageErrorIndicatorBuilder: (context) => FullPageErrorWidget(
            error: pagingErrorOf(state)?.error,
            stackTrace: pagingErrorOf(state)?.stackTrace,
            prefix: widget.newPageErrorPrefix,
            onRetry: fetchNextPage,
          ),
          noItemsFoundIndicatorBuilder: (context) => Center(child: Text(widget.emptyMessage)),
        ),
      ),
    );

    return Stack(
      children: [
        _wrapWithRefresh(list),
        if (_newPostsAvailable)
          Positioned(top: 12, left: 0, right: 0, child: Center(child: _buildNewPostsPill())),
      ],
    );
  }
}
