import 'package:flutter/foundation.dart';

/// Bridges the feed app-bar refresh button to the feed body's pull-to-refresh.
///
/// The body's [RefreshIndicator] registers a callback that shows its spinner and
/// runs the reload; the app-bar button invokes [refresh] to trigger that exact
/// same callback. This keeps both refresh entry points on a single code path.
///
/// [scrollToTop] is the other half of "tapping the active tab": the nav bar can
/// only reach the NestedScrollView's *outer* controller, which collapses the app
/// bar but leaves the inner list where the reader left it. The body owns the
/// list's controller, so it registers the real scroll-to-top here.
///
/// Handlers are keyed by feed: the Home tab keeps For You and Following alive at
/// the same time, and a single slot meant the last-mounted (usually hidden)
/// feed received the app-bar refresh.
class FeedRefreshController {
  final Map<Object, _FeedHandlers> _handlers = {};
  Object? activeFeedId;

  /// Registers [refresh]/[scrollToTop] and returns an ownership token. A feed
  /// rebuilt by an account switch mounts before the old one is disposed; the
  /// token stops the old dispose from removing the new handler.
  Object register(Object feedId,
      {required Future<void> Function() refresh, required VoidCallback scrollToTop}) {
    final token = Object();
    _handlers[feedId] = _FeedHandlers(refresh, scrollToTop, token);
    return token;
  }

  void unregister(Object feedId, Object token) {
    if (_handlers[feedId]?.token == token) _handlers.remove(feedId);
  }

  Future<void> refresh() async {
    await _handlers[activeFeedId]?.refresh();
  }

  void scrollToTop() {
    _handlers[activeFeedId]?.scrollToTop();
  }

  @visibleForTesting
  int get handlerCount => _handlers.length;
}

class _FeedHandlers {
  const _FeedHandlers(this.refresh, this.scrollToTop, this.token);

  final Future<void> Function() refresh;
  final VoidCallback scrollToTop;
  final Object token;
}
