import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Generated localization and build output: no requests live here.
bool _isAppSource(File file) {
  if (!file.path.endsWith('.dart')) return false;
  final generated = '${Platform.pathSeparator}generated${Platform.pathSeparator}';
  return !file.path.contains(generated);
}

/// Every Dart file under `lib/`, so a new client file cannot slip past the
/// read-only checks the way it did when they scanned three hand-listed paths.
List<File> appSources() =>
    Directory('lib').listSync(recursive: true).whereType<File>().where(_isAppSource).toList();

/// True for every spelling that reaches the network. Kept pure so the guard
/// itself has a regression test: a scanner that silently dropped `http.post`
/// would otherwise still pass while no production file used it.
bool isNetworkCall(String line) =>
    line.contains('quaxHttpClient.') ||
    line.contains('http.Request(') ||
    line.contains('http.Client(') ||
    // The top-level helpers are a second way to reach the network and were
    // invisible to the original scan: `http.post` in a new file would have
    // passed the only read-only guard.
    line.contains('http.get(') ||
    line.contains('http.post(') ||
    line.contains('http.put(') ||
    line.contains('http.delete(') ||
    line.contains('http.patch(') ||
    line.contains('http.head(') ||
    line.contains('http.read(') ||
    line.contains('client.send(') ||
    line.contains('client.post(') ||
    line.contains('client.get(') ||
    line.contains('client.getUrl(') ||
    line.contains('HttpClient(');

void main() {
  test('Should not call any mutating X operation', () {
    final sources = appSources().map((file) => file.readAsStringSync()).join('\n');

    const forbidden = [
      'CreateTweet',
      'DeleteTweet',
      'FavoriteTweet',
      'UnfavoriteTweet',
      'CreateRetweet',
      'DeleteRetweet',
      'CreateFollow',
      'DeleteFollow',
      'CreateBookmark',
      'DeleteBookmark',
      'favorites/create',
      'favorites/destroy',
      'friendships/create',
      'friendships/destroy',
      'statuses/update',
      'statuses/destroy',
      'direct_messages',
      'dm/new',
      'mute_users',
      'MarkEntriesRead',
    ];

    for (final operation in forbidden) {
      expect(sources.contains(operation), isFalse,
          reason: '$operation would change X state from a client that must stay read-only');
    }
  });

  test('Should only issue a request from the places that own the HTTP layer', () {
    // The read-only guarantee rests on there being exactly one way to reach the
    // network. A call site that builds its own request is how a mutation would
    // arrive without touching client.dart — which the old substring scan did
    // not cover, because it only looked at three files.
    final callSites = <String>[];
    for (final file in appSources()) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!isNetworkCall(lines[i])) continue;
        // Windows paths carry backslashes; compare on forward slashes.
        callSites.add('${file.path.replaceAll(r'\', '/')}:${i + 1}');
      }
    }

    const allowed = {
      'lib/client/client.dart',
      'lib/client/client_regular_account.dart',
      'lib/client/client_unauthenticated.dart',
      'lib/client/http_client.dart',
      'lib/client/x_client_transaction_id/client_transaction.dart',
      'lib/utils/downloads.dart',
      // The t.co resolver: a plain GET with no auth headers, following no
      // redirects. It cannot mutate anything and carries no session.
      'lib/utils/urls.dart',
    };

    for (final site in callSites) {
      final path = site.split(':').first;
      expect(allowed.contains(path), isTrue,
          reason: 'Only the HTTP layer may reach the network, and this call site is outside it. '
              'A request built elsewhere bypasses the account selector, the rate-limit tracker '
              'and the read-only guarantee: $site');
    }
  });

  test('Should recognise every way a request is built', () {
    expect(isNetworkCall("await http.post(uri, body: body)"), isTrue,
        reason: 'http.post reaches the network; missing it lets a mutation bypass the read-only guard');
    expect(isNetworkCall("final response = await http.get(uri);"), isTrue,
        reason: 'http.get is the same top-level path as http.post and must be scanned too');
    expect(isNetworkCall("final response = http.Response('', 200);"), isFalse,
        reason: 'Constructing an http.Response value is not a network call');
  });

  test('Should only import the HTTP package where the network layer lives', () {
    // The call-site scan is a substring check; an import allowlist makes the
    // boundary explicit and fails a new file before anyone has to spot a
    // particular call spelling. `exceptions.dart` only names http.Response.
    const allowedImports = {
      'lib/catcher/exceptions.dart',
      'lib/client/client.dart',
      'lib/client/client_regular_account.dart',
      'lib/client/client_unauthenticated.dart',
      'lib/client/http_client.dart',
      'lib/utils/downloads.dart',
      'lib/utils/urls.dart',
    };

    for (final file in appSources()) {
      final importsHttp = file.readAsLinesSync().any(
          (line) => line.contains("import 'package:http/http.dart"));
      if (!importsHttp) continue;

      final path = file.path.replaceAll(r'\', '/');
      expect(allowedImports.contains(path), isTrue,
          reason: 'A file outside the HTTP layer imported package:http. That bypasses the '
              'account selector, the rate-limit tracker and the read-only guarantee: $path');
    }
  });
}
