import 'dart:async';
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
Map<String, dynamic> payload(Object o) =>
    jsonDecode(jsonEncode(o)) as Map<String, dynamic>;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await L10n.load(const Locale('en'));
  });

  group('createTimelineChains', () {
    test('Should return an empty status instead of throwing when the home shape changed', () {
      final status = createTimelineChains(
        payload({
          'data': {'home': {}},
        }),
        'tweet',
        const [],
        false,
        () => 0,
        () {},
      );

      expect(
        status.chains,
        isEmpty,
        reason: 'A changed response shape should degrade to an empty feed, not crash the whole timeline',
      );
      expect(
        status.cursorBottom,
        isNull,
        reason: 'No entries means there is no cursor to paginate with',
      );
    });
  });

  group('user lists', () {
    Map<String, dynamic> userEntry(
      String id,
      String handle,
      Object? followers,
    ) => payload({
      'entryId': 'user-$id',
      'content': {
        'itemContent': {
          'user_results': {
            'result': {
              'rest_id': id,
              'legacy': {'screen_name': handle, 'followers_count': followers},
            },
          },
        },
      },
    });

    test('Should skip one malformed Following user and keep the rest', () {
      final body = payload({
        'data': {
          'user': {
            'result': {
              'timeline': {
                'timeline': {
                  'instructions': [
                    {
                      'type': 'TimelineAddEntries',
                      'entries': [
                        userEntry('1', 'bad', '12'),
                        userEntry('2', 'good', 12),
                      ],
                    },
                  ],
                },
              },
            },
          },
        },
      });

      final users = parseFollows(body);

      expect(
        users.users?.map((user) => user.screenName),
        ['good'],
        reason:
            'A count that arrived as a string used to throw inside the parse isolate and '
            'empty the whole Following page; one bad row should cost only that row',
      );
    });

    test('Should skip one malformed People result and keep the rest', () {
      final body = payload({
        'data': {
          'search_by_raw_query': {
            'search_timeline': {
              'timeline': {
                'instructions': [
                  {
                    'type': 'TimelineAddEntries',
                    'entries': [
                      userEntry('1', 'bad', '12'),
                      userEntry('2', 'good', 12),
                    ],
                  },
                ],
              },
            },
          },
        },
      });

      final page = parseSearchUsers(body);

      expect(
        page.users.map((user) => user.screenName),
        ['good'],
        reason: 'The People tab uses the same user shape and needs the same per-row isolation',
      );
    });
  });

  test('Should treat TimelineAddEntries without entries as an empty page', () {
    final status = parseTweetDetail(
      payload({
        'data': {
          'threaded_conversation_with_injections_v2': {
            'instructions': [
              {'type': 'TimelineAddEntries'},
            ],
          },
        },
      }),
    );

    expect(
      status.chains,
      isEmpty,
      reason:
          'A soft-error body can carry the instruction without the entries list; that is '
          'an empty page, not a reason to throw inside the isolate',
    );
  });

  group('createTweets', () {
    test('Should skip an entry without an entryId', () {
      final chains = createTweets([
        payload({'content': {}}),
      ]);

      expect(
        chains,
        isEmpty,
        reason:
            'One malformed entry should be skipped, not kill the whole page',
      );
    });

    test('Should skip a tweet entry whose tweet_results is missing (deleted tweet)', () {
      final chains = createTweets([
        payload({
          'entryId': 'tweet-1',
          'content': {'itemContent': {}},
        }),
      ]);

      expect(
        chains,
        isEmpty,
        reason: 'A deleted tweet should be omitted from the feed, not crash parsing',
      );
    });

    test('Should skip a tweet entry that carries no rest_id', () {
      final chains = createTweets([
        payload({
          'entryId': 'tweet-1',
          'content': {
            'itemContent': {
              'tweet_results': {
                'result': {'legacy': {}},
              },
            },
          },
        }),
      ]);

      expect(
        chains,
        isEmpty,
        reason:
            'An entry without a tweet id can neither be displayed nor opened',
      );
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
                  // 'core' arrives as a string instead of the user object the
                  // parser reads the author out of, which it cannot recover from
                  'core': 'not-an-object',
                },
              },
            },
          },
        }),
      ]);

      expect(
        chains,
        isEmpty,
        reason: 'One unparseable tweet should be dropped, not crash the whole page with it',
      );
    });

    test('Should keep the post when one of its card bindings has no key', () {
      final chains = createTweets([
        payload({
          'entryId': 'tweet-1',
          'content': {
            'itemContent': {
              'tweet_results': {
                'result': {
                  'rest_id': '1',
                  'legacy': {},
                  // A binding X has not named yet: the card simply loses that
                  // one value, and the post it decorates still renders.
                  'card': {
                    'legacy': {
                      'binding_values': [
                        {'value': {}},
                      ],
                    },
                  },
                },
              },
            },
          },
        }),
      ]);

      expect(
        chains,
        hasLength(1),
        reason:
            'Dropping the whole post over one unnamed card value threw away text and a '
            'footer that had nothing wrong with them',
      );
      expect(
        chains.single.tweets.single.card,
        isNotNull,
        reason:
            'The card itself is still readable, so it should be shown with the one unnamed '
            'binding missing rather than the post being dropped with it',
      );
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
                  'quoted_status_result': {
                    'result': {'__typename': 'TweetWithVisibilityResults'},
                  },
                },
              },
            },
          },
        }),
      ]);

      expect(
        chains,
        hasLength(1),
        reason: 'The quoted post being unavailable must not take the quoting post down with it',
      );
      expect(
        chains.first.tweets.first.quotedStatusWithCard,
        isNull,
        reason: 'The quote is simply not rendered when its payload is missing',
      );
    });
  });

  group('GraphQL response validation', () {
    Map<String, dynamic> searchBody(List<Map<String, dynamic>> entries) =>
        payload({
          'data': {
            'search_by_raw_query': {
              'search_timeline': {
                'timeline': {
                  'instructions': [
                    {'type': 'TimelineAddEntries', 'entries': entries},
                  ],
                },
              },
            },
          },
        });

    test(
      'Should reject a top-level GraphQL error before parsing a timeline',
      () async {
        await expectLater(
          parseOffThread<TweetStatus>(
            jsonEncode(
              payload({
                'errors': [
                  {'code': 32, 'message': 'Could not authenticate you'},
                ],
                'data': {},
              }),
            ),
            ParseJob.search,
            extra: 'Latest',
          ),
          throwsA(
            isA<TwitterError>().having((error) => error.code, 'code', 32),
          ),
          reason:
              'An error body with no timeline must surface X\'s reason instead of painting an '
              'empty search page or overwriting a thread cache',
        );
      },
    );

    test(
      'Should use the localized fallback for a non-string GraphQL message',
      () async {
        await expectLater(
          parseOffThread<TweetStatus>(
            jsonEncode(
              payload({
                'errors': [
                  {'code': 32, 'message': 42},
                ],
                'data': {},
              }),
            ),
            ParseJob.search,
            extra: 'Latest',
          ),
          throwsA(
            isA<TwitterError>()
                .having((error) => error.code, 'code', 32)
                .having(
                  (error) => error.message,
                  'message',
                  L10n.current.unknown_error,
                ),
          ),
          reason:
              'X owns the error shape; a numeric or object message must not throw a TypeError '
              'while reporting the original GraphQL error',
        );
      },
    );

    test('Should reject a response whose expected root moved', () async {
      await expectLater(
        parseOffThread<TweetStatus>(
          jsonEncode(
            payload({
              'data': {
                'user': {'result': {}},
              },
            }),
          ),
          ParseJob.search,
          extra: 'Latest',
        ),
        throwsA(isA<TwitterError>()),
        reason: 'HTTP 200 with a renamed root is a broken contract, not a genuinely empty page',
      );
    });

    test('Should preserve a genuinely empty timeline', () async {
      final status = await parseOffThread<TweetStatus>(
        jsonEncode(searchBody(const [])),
        ParseJob.search,
        extra: 'Latest',
      );

      expect(
        status.chains,
        isEmpty,
        reason: 'A present search root with no entries is a real empty result',
      );
      expect(
        status.cursorBottom,
        isNull,
        reason: 'There is no next page when the server returned no entries or cursor',
      );
    });
  });

  group('parseProfile() root contracts', () {
    TwitterError errorOf(Map<String, dynamic> body) {
      try {
        parseProfile(body, 'https://x.com/i/api/graphql/x/UserByScreenName');
      } on TwitterError catch (error) {
        return error;
      }
      fail('A broken profile root must throw a TwitterError');
    }

    test('Should reject present non-map data, user and result roots', () {
      for (final body in <Map<String, dynamic>>[
        payload({'data': 'moved'}),
        payload({
          'data': {
            'user': ['moved'],
          },
        }),
        payload({
          'data': {
            'user': {'result': 'moved'},
          },
        }),
      ]) {
        expect(
          errorOf(body).code,
          0,
          reason:
              'A present root with the wrong JSON type is a response-contract failure, '
              'not a missing user: $body',
        );
      }
    });

    test(
      'Should keep genuinely absent or null profile results as user-not-found',
      () {
        for (final body in <Map<String, dynamic>>[
          payload({'data': {}}),
          payload({
            'data': {
              'user': {'result': null},
            },
          }),
        ]) {
          expect(
            errorOf(body).code,
            50,
            reason: 'A genuinely missing result still maps to the actionable user-not-found error',
          );
        }
      },
    );
  });

  group('server ordering', () {
    Map<String, dynamic> tweetEntry(String id, String conversationId) =>
        payload({
          'entryId': 'tweet-$id',
          'content': {
            'itemContent': {
              'tweet_results': {
                'result': {
                  'rest_id': id,
                  'legacy': {
                    'id_str': id,
                    'conversation_id_str': conversationId,
                    'full_text': 'tweet $id',
                  },
                  'core': {
                    'user_results': {
                      'result': {
                        'rest_id': 'author',
                        'core': {'screen_name': 'author', 'name': 'Author'},
                      },
                    },
                  },
                },
              },
            },
          },
        });

    final entries = [
      tweetEntry('30', '30'),
      tweetEntry('10', '10'),
      tweetEntry('20', '20'),
    ];

    test(
      'Should preserve SearchTimeline entry order instead of sorting tweet ids',
      () {
        final status = parseSearchTimeline(
          payload({
            'data': {
              'search_by_raw_query': {
                'search_timeline': {
                  'timeline': {
                    'instructions': [
                      {'type': 'TimelineAddEntries', 'entries': entries},
                    ],
                  },
                },
              },
            },
          }),
        );

        expect(
          status.chains.map((chain) => chain.id),
          ['30', '10', '20'],
          reason:
              'Latest search is ordered by the server; sorting snowflake ids changes relevance '
              'and can move a newer reply ahead of the result X chose',
        );
      },
    );

    test('Should preserve bookmark entry and conversation order', () {
      final status = parseBookmarkTimeline(
        payload({
          'data': {
            'bookmark_timeline_v2': {
              'timeline': {
                'instructions': [
                  {'type': 'TimelineAddEntries', 'entries': entries},
                ],
              },
            },
          },
        }),
      );

      expect(
        status.chains.map((chain) => chain.id),
        ['30', '10', '20'],
        reason: 'Bookmarks are a reader-curated server-ordered list, not a chronological feed',
      );
    });
  });

  group('parseChainsOnIsolate() timeout', () {
    test('Should kill a timed-out parse isolate', () async {
      await expectLater(
        parseChainsOnIsolate(
          jsonEncode(
            payload({
              'data': {
                'home': {
                  'home_timeline_urt': {
                    'instructions': [],
                    'padding': 'x' * 60000,
                  },
                },
              },
            }),
          ),
          conversationless: false,
          tweetIndicator: 'tweet',
          pinnedTweets: const [],
          showPinnedTweet: false,
          getTweetsCounter: () => 0,
          incrementTweetsCounter: () {},
          parseTimeout: Duration.zero,
        ),
        throwsA(isA<TimeoutException>()),
        reason:
            'Isolate.run cannot be cancelled; a wedged parser must be killed so it does not '
            'leak an isolate and leave the feed on its skeleton',
      );
    });
  });

  group('createTweetChains', () {
    test('Should skip a tweet entry without tweet_results', () {
      final chains = createTweetChains([
        payload({
          'entryId': 'tweet-1',
          'content': {'itemContent': {}},
        }),
      ]);

      expect(
        chains,
        isEmpty,
        reason:
            'A tweet x.com cannot open should be skipped, not crash the thread',
      );
    });

    test(
      'Should fall back to a tombstone when a tweet result carries no rest_id',
      () {
        final chains = createTweetChains([
          payload({
            'entryId': 'tweet-123',
            'content': {
              'itemContent': {
                'tweet_results': {
                  'result': {'legacy': null},
                },
              },
            },
          }),
        ]);

        expect(
          chains,
          hasLength(1),
          reason:
              'The entry stays visible so the user knows a post exists there',
        );
        expect(
          chains.first.tweets.first.isTombstone,
          isTrue,
          reason: 'Without a rest_id the tweet can only render as a tombstone',
        );
      },
    );
  });
}
