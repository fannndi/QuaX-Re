import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/headers.dart';
import 'package:quax/client/http_client.dart';
import 'dart:async';
import 'package:quax/database/repository.dart';

class XRegularAccount extends ChangeNotifier {
  static final log = Logger('XRegularAccount');

  XRegularAccount() : super();

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
    database.delete(tableAccounts, where: 'id = ?', whereArgs: [username]);
    await promoteFirstAccountIfNoneActive();
  }
}
