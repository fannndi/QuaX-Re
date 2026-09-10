import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/client/client.dart';

/// X can change its response shapes at any time (see the parse-api skill): a
/// single malformed entry used to crash the whole feed instead of degrading.
///
/// Payloads go through jsonDecode(jsonEncode(..)) so they carry the exact types
/// the real responses have (jsonDecode maps), not test-literal types.
Map<String, dynamic> payload(Object o) => jsonDecode(jsonEncode(o)) as Map<String, dynamic>;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await L10n.load(const Locale('en'));
  });

  group('createTimelineChains', () {
    test('Should return an empty status instead of throwing when the home shape changed', () {
      final status = createTimelineChains(
        payload({'data': {'home': {}}}),
        'tweet',
        const [],
        true,
        false,
        false,
        () => 0,
        () {},
      );

      expect(status.chains, isEmpty,
          reason: 'A changed response shape should degrade to an empty feed, not crash the whole timeline');
      expect(status.cursorBottom, isNull, reason: 'No entries means there is no cursor to paginate with');
    });
  });

  group('createTweets', () {
    test('Should skip an entry without an entryId', () {
      final chains = createTweets([payload({'content': {}})]);

      expect(chains, isEmpty, reason: 'One malformed entry should be skipped, not kill the whole page');
    });

    test('Should skip a tweet entry whose tweet_results is missing (deleted tweet)', () {
      final chains = createTweets([
        payload({'entryId': 'tweet-1', 'content': {'itemContent': {}}}),
      ]);

      expect(chains, isEmpty, reason: 'A deleted tweet should be omitted from the feed, not crash parsing');
    });

    test('Should skip a tweet entry that carries no rest_id', () {
      final chains = createTweets([
        payload({
          'entryId': 'tweet-1',
          'content': {'itemContent': {'tweet_results': {'result': {'legacy': {}}}}},
        }),
      ]);

      expect(chains, isEmpty, reason: 'An entry without a tweet id can neither be displayed nor opened');
    });

    test('Should skip a tweet whose payload cannot be parsed, keeping the page alive', () {
      final chains = createTweets([
        payload({
          'entryId': 'tweet-1',
          'content': {
            'itemContent': {
              'tweet_results': {
                'result': {
                  'rest_id': '1',
                  'legacy': {},
                  // a card binding value without a key makes the card parsing throw
                  'card': {'legacy': {'binding_values': [{'value': {}}]}},
                }
              }
            }
          }
        }),
      ]);

      expect(chains, isEmpty,
          reason: 'One unparseable tweet should be dropped, not crash the whole page with it');
    });

    test('Should keep a tweet whose quoted tweet is unavailable', () {
      final chains = createTweets([
        payload({
          'entryId': 'tweet-1',
          'content': {
            'itemContent': {
              'tweet_results': {
                'result': {
                  'rest_id': '1',
                  'legacy': {},
                  'quoted_status_result': {'result': {'__typename': 'TweetWithVisibilityResults'}},
                }
              }
            }
          }
        }),
      ]);

      expect(chains, hasLength(1),
          reason: 'The quoted post being unavailable must not take the quoting post down with it');
      expect(chains.first.tweets.first.quotedStatusWithCard, isNull,
          reason: 'The quote is simply not rendered when its payload is missing');
    });
  });

  group('createTweetChains', () {
    test('Should skip a tweet entry without tweet_results', () {
      final chains = createTweetChains([
        payload({'entryId': 'tweet-1', 'content': {'itemContent': {}}}),
      ]);

      expect(chains, isEmpty, reason: 'A tweet x.com cannot open should be skipped, not crash the thread');
    });

    test('Should fall back to a tombstone when a tweet result carries no rest_id', () {
      final chains = createTweetChains([
        payload({
          'entryId': 'tweet-123',
          'content': {'itemContent': {'tweet_results': {'result': {'legacy': null}}}},
        }),
      ]);

      expect(chains, hasLength(1),
          reason: 'The entry stays visible so the user knows a post exists there');
      expect(chains.first.tweets.first.isTombstone, isTrue,
          reason: 'Without a rest_id the tweet can only render as a tombstone');
    });
  });
}


