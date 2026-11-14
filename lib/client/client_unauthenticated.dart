import 'dart:convert';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:quax/client/http_client.dart';
import 'package:quax/constants.dart';

String? _guestToken;

// What the last rate-limited response told us about the token. -1 means "no
// endpoint has reported a window yet", which is what lets a fresh token be used
// straight away. These were `const` once, so the checks below never saw them
// change and a cached token was handed out forever — once X expired it, every
// unauthenticated request failed until the app restarted.
int _expiresAt = -1;
int _tokenRemaining = -1;

/// Whether the cached guest token can serve another request. The counters stay
/// at -1 until an endpoint reports a window; that unknown state must not read
/// as "expired" or "exhausted". A reported budget of zero is the one value that
/// must force a new token: `remaining < limit` was true for an exhausted token
/// and handed it out for the rest of the window.
@visibleForTesting
bool guestTokenUsable({required int nowMs, required int expiresAt, required int remaining}) {
  if (remaining == 0) return false;
  if (expiresAt == -1) return true;
  return nowMs < expiresAt;
}

/// The guest path had no timeouts at all while every authenticated request was
/// bounded by `_defaultTimeout`. A hang here is worse than a hang there:
/// `fetch()` awaits it directly, so the future never completes and its
/// `_inflight` entry is never removed — every later request for the same URI
/// returns the hung future for the rest of the process.
const _guestTimeout = Duration(seconds: 15);

Future<String>? _tokenFuture;

Future<String> getToken(Logger log) {
  if (_guestToken != null &&
      guestTokenUsable(
          nowMs: DateTime.now().millisecondsSinceEpoch,
          expiresAt: _expiresAt,
          remaining: _tokenRemaining)) {
    return Future.value(_guestToken!);
  }

  // A cold start with no account fires several requests at once; without this
  // each one POSTs guest/activate.json and all but the last token are thrown
  // away (and guest activations are rate-limited).
  return _tokenFuture ??= _refreshToken(log).whenComplete(() => _tokenFuture = null);
}

Future<String> _refreshToken(Logger log) async {
  log.fine('Refreshing the X token');

  // Bounded: without it a dead-but-not-reset connection (the classic mobile-NAT
  // case where SYN is dropped) hangs this call forever, and fetch() awaits it
  // directly — so the whole fetch hangs and its _inflight entry is never
  // removed, poisoning that URI for the life of the process.
  var response = await quaxHttpClient
      .post(Uri.parse('https://api.x.com/1.1/guest/activate.json'), headers: {
    // Same bearer the authenticated path uses: the web client has one token,
    // and two different ones in one app is exactly the kind of tell to avoid.
    'Authorization': bearerToken,
  }).timeout(_guestTimeout);

  if (response.statusCode == 200) {
    var result = jsonDecode(response.body);
    if (result.containsKey('guest_token')) {
      _guestToken = result['guest_token'];

      return _guestToken!;
    }
  }

  _guestToken = null;

  throw Exception(
      'Unable to refresh the token. The response (${response.statusCode}) from Twitter was: ${response.body}');
}

Future<http.Response> _sendGuestRequest(Uri uri, Map<String, String>? headers, Logger log) async {
  return quaxHttpClient.get(uri, headers: {
    ...?headers,
    'Authorization': bearerToken,
    'x-guest-token': await getToken(log),
    'x-twitter-active-user': 'yes',
    'user-agent': userAgentHeader['user-agent']!
  }).timeout(_guestTimeout);
}

Future<http.Response> fetchUnauthenticated(Uri uri, {Map<String, String>? headers, required Logger log}) async {
  // The path only: the full URL's `variables` JSON embeds the reader's userId
  // and search terms, and this record reaches logcat in release.
  log.fine('Fetching (unauthenticated) ${uri.path}');

  var response = await _sendGuestRequest(uri, headers, log);

  // A rejected guest token is not recovered by waiting: X keeps answering
  // 401/403 until a new one is activated. Drop it and retry once.
  if (response.statusCode == 401 || response.statusCode == 403) {
    _guestToken = null;
    _expiresAt = -1;
    _tokenRemaining = -1;
    response = await _sendGuestRequest(uri, headers, log);
  }

  final headerRateLimitReset = response.headers['x-rate-limit-reset'];
  final headerRateLimitRemaining = response.headers['x-rate-limit-remaining'];

  if (headerRateLimitReset == null || headerRateLimitRemaining == null) {
    // If the rate limit headers are missing, the endpoint probably doesn't send them back
    return response;
  }

  // Update our token's rate limit counters, so the next call decides whether
  // this token can still be used or needs activating again. An endpoint that
  // doesn't report them keeps the "unknown" state and the token stays valid.
  final reset = int.tryParse(headerRateLimitReset);
  final remaining = int.tryParse(headerRateLimitRemaining);
  if (reset != null && remaining != null) {
    _expiresAt = reset * 1000;
    _tokenRemaining = remaining;
  }

  return response;
}
