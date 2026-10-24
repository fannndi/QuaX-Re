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
class FeedRefreshController {
  Future<void> Function()? _handler;
  VoidCallback? _scrollToTop;

  void register(Future<void> Function() handler) {
    _handler = handler;
  }

  void unregister(Future<void> Function() handler) {
    if (identical(_handler, handler)) {
      _handler = null;
    }
  }

  void registerScrollToTop(VoidCallback handler) {
    _scrollToTop = handler;
  }

  void unregisterScrollToTop(VoidCallback handler) {
    if (identical(_scrollToTop, handler)) {
      _scrollToTop = null;
    }
  }

  Future<void> refresh() async {
    await _handler?.call();
  }

  void scrollToTop() {
    _scrollToTop?.call();
  }
}
