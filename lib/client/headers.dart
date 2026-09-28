import 'dart:async';

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
    'user-agent': userAgentHeader['user-agent']!,
    'x-twitter-active-user': 'yes',
    'x-twitter-client-language': 'en',
  };

  static Future<ClientTransaction>? _initFuture;
  static DateTime? _initializedAt;

  // After a failed initialization no attempt is retried for this long: the
  // init fetches x.com/home plus an ondemand script, and a broken page shape
  // would otherwise repeat both on every API call.
  static const _failureCooldown = Duration(minutes: 2);
  @visibleForTesting
  static DateTime? failureRetryAt;

  // initialize() fetches and parses x.com/home plus an ondemand script: bound
  // it, so a hanging request cannot stall every API call for the whole session.
  static const _initTimeout = Duration(seconds: 15);

  // X rotates the keys the transaction id is derived from with their deploys.
  // After a 404, the cached generator is dropped at most once per cooldown, so
  // a stale generator self-heals on the next request without hammering x.com.
  static const _stalenessCooldown = Duration(minutes: 10);

  /// Clears the module state between tests.
  @visibleForTesting
  static void resetForTests() {
    _initFuture = null;
    _initializedAt = null;
    failureRetryAt = null;
  }

  /// The transaction id header, or null when it cannot be produced. A failure
  /// here must fail open: X only loosely requires the header, so the request
  /// proceeds without it instead of killing the timeline.
  static Future<Map<String, String>?> getXClientTransactionIdHeader(
    Uri? uri, {
    String method = 'GET',
  }) async {
    if (uri == null) {
      return null;
    }

    final now = DateTime.now();
    if (failureRetryAt != null && now.isBefore(failureRetryAt!)) {
      // Inside the backoff window: no header, no new attempt.
      return null;
    }

    try {
      _initFuture ??= ClientTransaction.initialize().timeout(_initTimeout).then(
        (ct) {
          _initializedAt = DateTime.now();
          return ct;
        },
      );
      final ct = await _initFuture!;
      failureRetryAt = null;
      return {
        'x-client-transaction-id': ct.generateTransactionId(method, uri.path),
      };
    } catch (e) {
      // A failed (or timed out) initialization must not stay cached: futures
      // keep their error, so every later request would fail the same way until
      // the app restarts. The scrape can also legitimately break — X changing
      // the page shape raises "Couldn't find ondemand file index" here. Either
      // way, fail open and let the request go out without the header.
      _initFuture = null;
      _initializedAt = null;
      failureRetryAt = now.add(_failureCooldown);
      log.warning(
        'x-client-transaction-id unavailable, continuing without it: $e',
      );
      return null;
    }
  }

  /// Drops the cached transaction generator if it is old enough that X may have
  /// rotated its keys, so the next request re-derives them. A no-op within the
  /// cooldown, since a fresh generator is very unlikely to be the 404's cause.
  static void invalidateIfStale() {
    final at = _initializedAt;
    if (at == null) {
      return;
    }
    if (DateTime.now().difference(at) >= _stalenessCooldown) {
      _initFuture = null;
      _initializedAt = null;
    }
  }

  static Future<Map<String, String>> getHeaders(
    Uri? uri,
    Map<dynamic, dynamic>? authHeader, {
    String method = 'GET',
  }) async {
    final xClientTransactionIdHeader = await getXClientTransactionIdHeader(
      uri,
      method: method,
    );
    return {
      ..._baseHeaders,
      // Auth values come from a stored JSON decode: a non-string value (a
      // number after an X change) must not kill the request here.
      if (authHeader != null) ...{
        for (final entry in authHeader.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      },
      ...?xClientTransactionIdHeader,
    };
  }
}
