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
        final line = lines[i];
        final isCall = line.contains('quaxHttpClient.') ||
            line.contains('http.Request(') ||
            line.contains('client.send(') ||
            line.contains('client.post(') ||
            line.contains('client.get(') ||
            line.contains('client.getUrl(') ||
            line.contains('HttpClient(');
        if (!isCall) continue;
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
}
