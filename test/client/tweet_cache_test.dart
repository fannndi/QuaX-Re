import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';

void main() {
  // The text of a tombstone falls back to a translated string.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await L10n.load(const Locale('en'));
  });

  /// What the feed cache does between two launches: store the chains, read them back.
  TweetChain throughTheCache(TweetChain chain) =>
      TweetChain.fromJson(jsonDecode(jsonEncode(chain.toJson())) as Map<String, dynamic>);

  group('TweetChain.fromJson()', () {
    test('Should still read a tombstone as a tombstone after it went through the cache', () {
      final chain = TweetChain(id: '1', tweets: [TweetWithCard.tombstone({})], isPinned: false);

      expect(throughTheCache(chain).tweets.single.isTombstone, isTrue,
          reason: 'A tombstone is rendered as an error message. One that loses its flag in the '
              'cache is rendered as an ordinary tweet instead, and it carries neither an author '
              'nor a display text range, so building its tile throws');
    });
  });

  group('TweetWithCard.tombstone()', () {
    test('Should show the reason X gave, not the generic fallback', () {
      final tombstone = TweetWithCard.tombstone({
        'richText': {'text': 'This post was deleted. Learn more'}
      });

      expect(tombstone.text, 'This post was deleted.',
          reason: 'X says why a post is unavailable, and that reason is what the reader should '
              'read. Falling back to the generic string throws that information away while it sat '
              'unused in the payload');
    });

    test('Should strip the trailing "Learn more" X appends', () {
      final tombstone = TweetWithCard.tombstone({
        'text': {'text': 'This post is from an account you blocked. Learn more'}
      });

      expect(tombstone.text, 'This post is from an account you blocked.',
          reason: 'The suffix belongs to X\'s link markup, not to the message');
    });

    test('Should fall back to the generic text only when there is nothing to read', () {
      expect(TweetWithCard.tombstone({}).text, L10n.current.this_tweet_is_unavailable,
          reason: 'An empty payload has no reason to show, so the translated fallback is the right '
              'answer');
    });

    test('Should survive a payload that is not shaped the way we expect', () {
      expect(TweetWithCard.tombstone('not a map').text, L10n.current.this_tweet_is_unavailable,
          reason: 'A tombstone payload X reshapes must not turn a "this post was deleted" card '
              'into a thrown TypeError inside the parse isolate, which would surface as a generic '
              'failure instead of the card');
      expect(TweetWithCard.tombstone({'richText': 'not a map'}).text, L10n.current.this_tweet_is_unavailable,
          reason: 'The same for a field that is present but not an object');
      expect(TweetWithCard.tombstone({'richText': {'text': 42}}).text, L10n.current.this_tweet_is_unavailable,
          reason: 'And for a text field that is not a string');
    });
  });
}
