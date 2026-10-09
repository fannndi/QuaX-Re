import 'dart:convert';
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
int _tokenLimit = -1;
int _tokenRemaining = -1;

Future<String> getToken(Logger log) async {
  if (_guestToken != null) {
    // No rate limit reported yet: the token is as good as it was when we got it
    if (_expiresAt == -1 && _tokenLimit == -1 && _tokenRemaining == -1) {
      return _guestToken!;
    }

    // Still inside the window, with budget left
    if (DateTime.now().millisecondsSinceEpoch < _expiresAt && _tokenRemaining < _tokenLimit) {
      return _guestToken!;
    }
  }

  log.info('Refreshing the X token');

  var response = await quaxHttpClient.post(Uri.parse('https://api.x.com/1.1/guest/activate.json'), headers: {
    // Same bearer the authenticated path uses: the web client has one token,
    // and two different ones in one app is exactly the kind of tell to avoid.
    'Authorization': bearerToken,
  });

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

Future<http.Response> fetchUnauthenticated(Uri uri, {Map<String, String>? headers, required Logger log}) async {
  log.info('Fetching (unauthenticated) $uri');

  var response = await quaxHttpClient.get(uri, headers: {
    ...?headers,
    'Authorization': bearerToken,
    'x-guest-token': await getToken(log),
    'x-twitter-active-user': 'yes',
    'user-agent': userAgentHeader['user-agent']!
  });

  var headerRateLimitReset = response.headers['x-rate-limit-reset'];
  var headerRateLimitRemaining = response.headers['x-rate-limit-remaining'];
  var headerRateLimitLimit = response.headers['x-rate-limit-limit'];

  if (headerRateLimitReset == null || headerRateLimitRemaining == null || headerRateLimitLimit == null) {
    // If the rate limit headers are missing, the endpoint probably doesn't send them back
    return response;
  }

  // Update our token's rate limit counters, so the next call decides whether
  // this token can still be used or needs activating again. An endpoint that
  // doesn't report them keeps the "unknown" state and the token stays valid.
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
