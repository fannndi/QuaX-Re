import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/headers.dart';
import 'package:quax/client/http_client.dart';
import 'dart:async';

/// Test seam for the account-selection policy. The production path is the
/// default; a test can return canned responses without opening a socket.
typedef DebugFetchOverride = Future<http.Response> Function(
  Uri uri, {
  Map<String, String>? headers,
  String? body,
  required Logger log,
  required Map<dynamic, dynamic> authHeader,
});

/// Fetches as the reader's own login. Nothing notifies: this is a plain
/// client object constructed per request, not a store — extending ChangeNotifier
/// here only allocated a listener set that nothing ever read from.
class XRegularAccount {
  static final log = Logger('XRegularAccount');

  @visibleForTesting
  static DebugFetchOverride? debugFetchOverride;

  Future<http.Response> fetch(Uri uri,
      {Map<String, String>? headers,
      String? body,
      required Logger log,
      required Map<dynamic, dynamic> authHeader}) async {
    final override = debugFetchOverride;
    if (override != null) {
      return override(uri, headers: headers, body: body, log: log, authHeader: authHeader);
    }

    // The path only: a full URL carries the GraphQL `variables` JSON, which
    // embeds the reader's numeric userId and their search terms. `fine` so a
    // release build never records it.
    log.fine('Fetching ${uri.path}');

    final method = body == null ? 'GET' : 'POST';
    final baseHeaders = await TwitterHeaders.getHeaders(uri, authHeader, method: method);

    if (body == null) {
      return await quaxHttpClient.get(uri, headers: {...?headers, ...baseHeaders});
    }

    // GraphQL operations that X now requires as POST send a JSON body.
    return await quaxHttpClient.post(uri,
        headers: {...?headers, ...baseHeaders, 'Content-Type': 'application/json'}, body: body);
  }

  Future<void> deleteAccount(String id) async {
    // Also removes the local likes owned by this account; the shared tweet
    // bodies are cleaned up only when no other account still references them.
    await deleteAccountAndLocalLikes(id);
  }
}
