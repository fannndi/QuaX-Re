import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:quax/client/http_client.dart';
import 'package:quax/constants.dart';

const String _guestAuthHeader =
    'Bearer AAAAAAAAAAAAAAAAAAAAAGHtAgAAAAAA%2Bx7ILXNILCqkSGIzy6faIHZ9s3Q%3DQy97w6SIrzE7lQwPJEYQBsArEE2fC25caFwRBvAGi456G09vGR';

String? _guestToken;
int _expiresAt = -1;
int _tokenLimit = -1;
int _tokenRemaining = -1;
// Single-flight: concurrent getToken calls share one activation instead of
// each activating (and burning) their own guest token.
Future<String>? _tokenFuture;

/// Clears the module state between tests: tokens, counters and the in-flight
/// memo all start fresh.
@visibleForTesting
void resetGuestTokenForTests() {
  _guestToken = null;
  _expiresAt = -1;
  _tokenLimit = -1;
  _tokenRemaining = -1;
  _tokenFuture = null;
}

Future<String> getToken(Logger log) {
  return _tokenFuture ??= _refreshToken(log)
      .whenComplete(() => _tokenFuture = null);
}

Future<String> _refreshToken(Logger log) async {
  if (_guestToken != null) {
    // If no rate-limit headers were seen yet, the token is brand new: assume
    // it is fine. Otherwise reuse it only while the window has not expired and
    // usages remain.
    final nothingTracked =
        _expiresAt == -1 && _tokenLimit == -1 && _tokenRemaining == -1;
    final stillValid =
        DateTime.now().millisecondsSinceEpoch < _expiresAt &&
        (_tokenRemaining == -1 || _tokenRemaining < _tokenLimit);

    if (nothingTracked || stillValid) {
      return _guestToken!;
    }

    // Expired or exhausted: drop it so a fresh one is activated below.
    _guestToken = null;
  }

  log.info('Refreshing the X token');

  final response = await quaxHttpClient.post(
    Uri.parse('https://api.x.com/1.1/guest/activate.json'),
    headers: {'Authorization': _guestAuthHeader},
  );

  if (response.statusCode == 200) {
    final result = jsonDecode(response.body);
    final token = result is Map<String, dynamic>
        ? result['guest_token'] as String?
        : null;
    if (token != null) {
      _guestToken = token;

      return _guestToken!;
    }
  }

  _guestToken = null;

  throw Exception(
    'Unable to refresh the token. The response (${response.statusCode}) from Twitter was: ${response.body}',
  );
}

Future<http.Response> fetchUnauthenticated(
  Uri uri, {
  Map<String, String>? headers,
  required Logger log,
}) async {
  log.info('Fetching (unauthenticated) $uri');

  var response = await quaxHttpClient.get(
    uri,
    headers: {
      ...?headers,
      'Authorization': _guestAuthHeader,
      'x-guest-token': await getToken(log),
      'x-twitter-active-user': 'yes',
      'user-agent': userAgentHeader['user-agent']!,
    },
  );

  var headerRateLimitReset = response.headers['x-rate-limit-reset'];
  var headerRateLimitRemaining = response.headers['x-rate-limit-remaining'];
  var headerRateLimitLimit = response.headers['x-rate-limit-limit'];

  if (headerRateLimitReset == null ||
      headerRateLimitRemaining == null ||
      headerRateLimitLimit == null) {
    // If the rate limit headers are missing, the endpoint probably doesn't send them back
    return response;
  }

  // Update our token's rate limit counters. Malformed numbers are ignored:
  // with the old state kept, the token is re-checked on the next call.
  final reset = int.tryParse(headerRateLimitReset);
  final remaining = int.tryParse(headerRateLimitRemaining);
  final limit = int.tryParse(headerRateLimitLimit);
  if (reset != null && remaining != null && limit != null) {
    _expiresAt = reset * 1000;
    _tokenRemaining = remaining;
    _tokenLimit = limit;
  }

  return response;
}
