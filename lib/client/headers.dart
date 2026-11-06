import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logging/logging.dart';
import 'package:quax/client/x_client_transaction_id/client_transaction.dart';
import 'package:quax/constants.dart';

class TwitterHeaders {
  static final log = Logger('TwitterHeaders');

  static final Map<String, String> _baseHeaders = {
    'accept': '*/*',
    'accept-language': 'en-US,en;q=0.9',
    'authorization': bearerToken,
    'cache-control': 'no-cache',
    'content-type': 'application/json',
    'pragma': 'no-cache',
    'priority': 'u=1, i',
    'referer': 'https://x.com/',
    'sec-ch-ua': '"Chromium";v="152", "Not?A_Brand";v="24"',
    'sec-ch-ua-mobile': '?1',
    'sec-ch-ua-platform': '"Android"',
    'user-agent': userAgentHeader['user-agent']!,
    'x-twitter-active-user': 'yes',
    'x-twitter-client-language': 'en',
  };

  static Future<ClientTransaction>? _initFuture;
  static DateTime? _initializedAt;
  static DateTime? _deriveDisabledUntil;

  // initialize() fetches and parses x.com/home plus an ondemand script: bound
  // it, so a hanging request cannot stall every API call for the whole session.
  static const _initTimeout = Duration(seconds: 15);

  // X rotates the keys the transaction id is derived from with their deploys.
  // After a 404, the cached generator is dropped at most once per cooldown, so
  // a stale generator self-heals on the next request without hammering x.com.
  static const _stalenessCooldown = Duration(minutes: 10);

  // When deriving fails outright — X serving a page shape this port does not
  // understand — every request would otherwise pay for a fresh attempt. Between
  // attempts, requests simply go without the header.
  static const _deriveCooldown = Duration(minutes: 5);

  // A 403 means the transaction key itself is wrong, unlike the age-based 404
  // path. Force one re-derivation, then back off so a broken page cannot make
  // every request pay for the 16-chunk initialization.
  static const _forcedInvalidationCooldown = Duration(seconds: 60);
  static DateTime? _lastForcedInvalidation;

  static Future<Map<String, String>?> getXClientTransactionIdHeader(Uri? uri, {String method = 'GET'}) async {
    if (uri == null) {
      return null;
    }

    final disabledUntil = _deriveDisabledUntil;
    if (disabledUntil != null && DateTime.now().isBefore(disabledUntil)) {
      return null;
    }

    try {
      _initFuture ??= ClientTransaction.initialize().timeout(_initTimeout).then((ct) {
        _initializedAt = DateTime.now();
        return ct;
      });
      final ct = await _initFuture!;
      return {'x-client-transaction-id': ct.generateTransactionId(method, uri.path)};
    } catch (e) {
      // Deriving the id reads a page X owns and reshapes whenever they deploy —
      // they have moved it outright before (the x-web migration of 2026), and
      // then nothing this port knows how to parse is there. That must not take
      // every request down with it: the header is mandatory on only a handful of
      // operations, so the request goes out without it and those endpoints report
      // themselves. Keep the failed future out of the cache, back off, log.
      _initFuture = null;
      _initializedAt = null;
      _deriveDisabledUntil = DateTime.now().add(_deriveCooldown);
      log.warning('No x-client-transaction-id for the next ${_deriveCooldown.inMinutes} min: $e');
      return null;
    }
  }

  /// Drops the cached transaction generator if it is old enough that X may have
  /// rotated its keys, so the next request re-derives them. A no-op within the
  /// cooldown, since a fresh generator is very unlikely to be the 404's cause.
  ///
  /// Also ends a failure back-off early — a 404 means the page moved again,
  /// which is exactly the kind of change a retry is worth making for. Only when
  /// the derivation has actually succeeded at least once, though: a 404 on a
  /// rotated queryId (the common cause, per the comment in `fetch()`) used to
  /// clear the back-off unconditionally, so a fundamentally broken derivation
  /// re-attempted `ClientTransaction.initialize()` — up to 16 chunk requests —
  /// on every single 404 with no back-off at all.
  static void invalidateIfStale() {
    final at = _initializedAt;
    if (at == null) {
      // Never derived successfully: a 404 says nothing about the page shape, so
      // the back-off stands.
      return;
    }
    _deriveDisabledUntil = null;

    if (DateTime.now().difference(at) >= _stalenessCooldown) {
      _initFuture = null;
      _initializedAt = null;
    }
  }

  /// Drops the cached transaction generator after a 403, which means the key
  /// itself is wrong (not merely old). Returns true when a retry is worth
  /// making; the cooldown keeps a permanently broken page from re-running the
  /// 16-chunk derivation on every request.
  static bool invalidateNow() {
    final now = DateTime.now();
    final last = _lastForcedInvalidation;
    if (last != null && now.difference(last) < _forcedInvalidationCooldown) {
      return false;
    }
    _lastForcedInvalidation = now;
    _initFuture = null;
    _initializedAt = null;
    _deriveDisabledUntil = null;
    return true;
  }

  @visibleForTesting
  static void resetForTests() {
    _initFuture = null;
    _initializedAt = null;
    _deriveDisabledUntil = null;
    _lastForcedInvalidation = null;
  }

  static Future<Map<String, String>> getHeaders(Uri? uri, Map<dynamic, dynamic>? authHeader,
      {String method = 'GET'}) async {
    final xClientTransactionIdHeader = await getXClientTransactionIdHeader(uri, method: method);
    return {
      ..._baseHeaders,
      // The web client marks authenticated requests with this; omitting it is
      // one more way a port looks different from the real session.
      if (authHeader != null) 'x-twitter-auth-type': 'OAuth2Session',
      if (authHeader != null) ...Map<String, String>.from(authHeader),
      ...?xClientTransactionIdHeader
    };
  }
}
