import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/headers.dart';
import 'package:quax/client/http_client.dart';
import 'dart:async';
import 'package:quax/database/repository.dart';

/// Fetches as the reader's own login. Nothing notifies: this is a plain
/// client object constructed per request, not a store — extending ChangeNotifier
/// here only allocated a listener set that nothing ever read from.
class XRegularAccount {
  static final log = Logger('XRegularAccount');

  Future<http.Response> fetch(Uri uri,
      {Map<String, String>? headers,
      String? body,
      required Logger log,
      required Map<dynamic, dynamic> authHeader}) async {
    log.info('Fetching $uri');

    final baseHeaders = await TwitterHeaders.getHeaders(uri, authHeader);

    if (body == null) {
      return await quaxHttpClient.get(uri, headers: {...?headers, ...baseHeaders});
    }

    // GraphQL operations that X now requires as POST send a JSON body.
    return await quaxHttpClient.post(uri,
        headers: {...?headers, ...baseHeaders, 'Content-Type': 'application/json'}, body: body);
  }

  Future<void> deleteAccount(String username) async {
    var database = await Repository.writable();
    // Awaited: promoteFirstAccountIfNoneActive() reads straight afterwards and
    // would happily promote the row we meant to remove.
    await database.delete(tableAccounts, where: 'id = ?', whereArgs: [username]);
    await promoteFirstAccountIfNoneActive();
  }
}
