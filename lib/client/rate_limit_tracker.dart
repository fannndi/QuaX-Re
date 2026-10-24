import 'package:flutter/foundation.dart' show visibleForTesting;

/// In-memory, per-endpoint rate-limit memory.
///
/// X rate limits are per-endpoint, not per-account-globally: an account can be
/// `429` on `/SearchTimeline` while still serving `/TweetDetail`. We therefore
/// remember the reset time keyed by (account, endpoint). State is intentionally
/// not persisted — 429 windows are short (~15 min), so a restart simply forgets
/// them.
class RateLimitTracker {
  static final Map<String, Map<String, DateTime>> _resetByAccountEndpoint = {};

  static bool isLimited(String accountId, String endpoint, DateTime now) {
    final reset = _resetByAccountEndpoint[accountId]?[endpoint];
    return reset != null && reset.isAfter(now);
  }

  static void flag(String accountId, String endpoint, DateTime resetAt) {
    (_resetByAccountEndpoint[accountId] ??= {})[endpoint] = resetAt;
  }

  static void clear(String accountId, String endpoint) {
    _resetByAccountEndpoint[accountId]?.remove(endpoint);
  }

  /// Test hook: forgets every flag. The map is a process-wide static that
  /// production code reads on every request (`fetch()` asks `isLimited`), so a
  /// flag written by one test file would otherwise still be there for a later
  /// one — `flutter test` runs them all in one process.
  @visibleForTesting
  static void clearForTests() {
    _resetByAccountEndpoint.clear();
  }
}
