import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The app is a reader: it must never call an endpoint that changes X state.
/// A single accidental mutation runs against the reader's real account and is
/// visible on their timeline. None of the features need one — likes and saves
/// are local, bookmarks and likes are only read.
void main() {
  test('Should not call any mutating X operation', () {
    final sources = [
      'lib/client/client.dart',
      'lib/client/client_unauthenticated.dart',
      'lib/client/client_regular_account.dart',
    ].map((path) => File(path).readAsStringSync()).join('\n');

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
    ];

    for (final operation in forbidden) {
      expect(sources.contains(operation), isFalse,
          reason: '$operation would change X state from a client that must stay read-only');
    }
  });
}
