import 'package:quax/client/x_client_transaction_id/client_transaction.dart';
import 'package:quax/constants.dart';

class TwitterHeaders {
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

  // initialize() fetches and parses x.com/home plus an ondemand script: bound
  // it, so a hanging request cannot stall every API call for the whole session.
  static const _initTimeout = Duration(seconds: 15);

  // X rotates the keys the transaction id is derived from with their deploys.
  // After a 404, the cached generator is dropped at most once per cooldown, so
  // a stale generator self-heals on the next request without hammering x.com.
  static const _stalenessCooldown = Duration(minutes: 10);

  static Future<Map<String, String>?> getXClientTransactionIdHeader(Uri? uri) async {
    if (uri == null) {
      return null;
    }

    try {
      _initFuture ??= ClientTransaction.initialize().timeout(_initTimeout).then((ct) {
        _initializedAt = DateTime.now();
        return ct;
      });
      final ct = await _initFuture!;
      return {'x-client-transaction-id': ct.generateTransactionId('GET', uri.path)};
    } on Exception {
      // A failed (or timed out) initialization must not stay cached: futures
      // keep their error, so every later request would fail the same way until
      // the app restarts. Drop it and let the next request try afresh.
      _initFuture = null;
      _initializedAt = null;
      rethrow;
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

  static Future<Map<String, String>> getHeaders(Uri? uri, Map<dynamic, dynamic>? authHeader) async {
    final xClientTransactionIdHeader = await getXClientTransactionIdHeader(uri);
    return {
      ..._baseHeaders,
      if (authHeader != null) ...Map<String, String>.from(authHeader),
      ...?xClientTransactionIdHeader
    };
  }
}
