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
    if (reset == null) return false;
    if (!reset.isAfter(now)) {
      // Expired windows are dead weight: drop them instead of letting every
      // account-endpoint pair accumulate for the whole session.
      _resetByAccountEndpoint[accountId]!.remove(endpoint);
      if (_resetByAccountEndpoint[accountId]!.isEmpty) {
        _resetByAccountEndpoint.remove(accountId);
      }
      return false;
    }
    return true;
  }

  static void flag(String accountId, String endpoint, DateTime resetAt) {
    (_resetByAccountEndpoint[accountId] ??= {})[endpoint] = resetAt;
  }

  static void clear(String accountId, String endpoint) {
    _resetByAccountEndpoint[accountId]?.remove(endpoint);
  }

  /// Live (non-expired) limits as a plain document: for the debug bridge, so
  /// an agent can see which account-endpoint pairs are currently cooling.
  static Map<String, dynamic> snapshot(DateTime now) {
    final out = <String, Map<String, String>>{};
    _resetByAccountEndpoint.forEach((account, endpoints) {
      final live = <String, String>{};
      endpoints.forEach((endpoint, reset) {
        if (reset.isAfter(now)) {
          live[endpoint] = reset.toIso8601String();
        }
      });
      if (live.isNotEmpty) {
        out[account] = live;
      }
    });
    return out;
  }
}
