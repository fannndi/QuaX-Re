import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/client.dart';

void main() {
  final fixture = jsonDecode(File('test/fixtures/HomeTimeline/vars-2a4d9c.json').readAsStringSync())
      as Map<String, dynamic>;
  final body = jsonEncode(fixture['body']);

  Future<TweetStatus> parse(String json, {required int Function() counter, required void Function() bump}) =>
      parseChainsOnIsolate(json,
          conversationless: false,
          tweetIndicator: 'tweet',
          pinnedTweets: const [],
          mapToThreads: true,
          includeReplies: false,
          showPinnedTweet: false,
          getTweetsCounter: counter,
          incrementTweetsCounter: bump);

  /// The recorded page trimmed down to one chain and its bottom cursor, which
  /// is what X answers when the feed has nothing fresher to give.
  String nearEmptyPage() {
    final instructions =
        (fixture['body']['data']['home']['home_timeline_urt']['instructions'] as List)
            .cast<Map<String, dynamic>>();
    final addEntries = instructions.firstWhere((e) => e['type'] == 'TimelineAddEntries');
    final entries = (addEntries['entries'] as List).cast<Map<String, dynamic>>();
    addEntries['entries'] = [
      entries.firstWhere((e) => (e['entryId'] as String).startsWith('tweet-')),
      entries.firstWhere((e) => (e['entryId'] as String).startsWith('cursor-bottom')),
    ];
    return jsonEncode(fixture['body']);
  }

  test('Should parse a full timeline page off the calling isolate', () async {
    var counter = 0;

    final status = await parse(body, counter: () => counter, bump: () => counter++);

    expect(status.chains, isNotEmpty,
        reason: 'The isolate hop must not lose the page: an empty result reads as a broken feed');
    expect(status.cursorBottom, isNotNull,
        reason: 'A full page has a bottom cursor, so pagination has to keep going');
    expect(status.chains.expand((chain) => chain.tweets).every((tweet) => tweet.user != null), isTrue,
        reason: 'Parsing happens on another isolate, so the tweet objects must survive the trip '
            'with their authors (they are dropped silently otherwise)');
    expect(counter, 0,
        reason: 'A full page is not a near-empty one, so it must not count towards the give-up '
            'limit');
  });

  test('Should count a near-empty page on the calling isolate', () async {
    var counter = 0;

    final small = await parse(nearEmptyPage(), counter: () => counter, bump: () => counter++);

    expect(small.chains, hasLength(1),
        reason: 'The trimmed page holds exactly one chain, which is what makes it "near-empty"');
    expect(counter, 1,
        reason: 'The counter lives in the feed, not in the isolate, so the parse has to hand the '
            'increment back to the caller');
    expect(small.cursorBottom, isNotNull,
        reason: 'One near-empty page is not enough to stop paginating');
  });

  test('Should stop paginating after the fifth near-empty page', () async {
    var counter = 5;

    final small = await parse(nearEmptyPage(), counter: () => counter, bump: () => counter++);

    expect(small.cursorBottom, isNull,
        reason: 'X can answer page after page of near-empty results; without dropping the cursor '
            'the pager would keep asking forever');
  });
}
