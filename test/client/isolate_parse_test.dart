import 'dart:convert';
import 'dart:io';

import 'package:dart_twitter_api/twitter_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/client.dart';
import 'package:quax/profile/profile_model.dart';

/// The recorded response body of a fixture, as the client would receive it.
String fixtureBody(String operation, {String? file}) {
  final directory = Directory('test/fixtures/$operation');
  final fixture = file != null
      ? File('${directory.path}/$file')
      : directory.listSync().whereType<File>().first;
  return jsonEncode((jsonDecode(fixture.readAsStringSync()) as Map<String, dynamic>)['body']);
}

void main() {
  final body = fixtureBody('HomeTimeline');

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
    final fixture = jsonDecode(fixtureBody('HomeTimeline')) as Map<String, dynamic>;
    final instructions = (fixture['data']['home']['home_timeline_urt']['instructions'] as List)
        .cast<Map<String, dynamic>>();
    final addEntries = instructions.firstWhere((e) => e['type'] == 'TimelineAddEntries');
    final entries = (addEntries['entries'] as List).cast<Map<String, dynamic>>();
    addEntries['entries'] = [
      entries.firstWhere((e) => (e['entryId'] as String).startsWith('tweet-')),
      entries.firstWhere((e) => (e['entryId'] as String).startsWith('cursor-bottom')),
    ];
    return jsonEncode(fixture);
  }

  group('parseChainsOnIsolate()', () {
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
  });

  group('parseOffThread()', () {
    /// Some fixtures record empty or error answers on purpose, so the tests
    /// walk the recorded pages until one parses into the shape they assert on.
    Future<T?> firstUsable<T>(String operation, Future<T> Function(String body) parse, bool Function(T) usable) async {
      for (final file in Directory('test/fixtures/$operation').listSync().whereType<File>()) {
        final body = jsonEncode((jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)['body']);
        final T result;
        try {
          result = await parse(body);
        } catch (_) {
          continue; // A recorded error answer is not what this test is after.
        }
        if (usable(result)) return result;
      }
      return null;
    }

    test('Should bring a thread page back with its replies', () async {
      final status = await parseOffThread<TweetStatus>(fixtureBody('TweetDetail'), ParseJob.tweetDetail);

      expect(status.chains, isNotEmpty,
          reason: 'The thread screen paints from this result; losing it would show an empty thread');
      expect(status.chains.expand((chain) => chain.tweets).every((tweet) => tweet.user != null), isTrue,
          reason: 'Tweets must survive the isolate trip with their authors');
    });

    test('Should bring a follows page back as a users list', () async {
      // The recorded following page is an empty one (X terminates the
      // timeline), which is exactly what the empty state has to handle.
      final follows = await parseOffThread<PaginatedUsers>(fixtureBody('Following'), ParseJob.follows);

      expect(follows.users, isNotNull,
          reason: 'A follow list should come back as a list, even an empty one, so the screen can '
              'show its empty state instead of waiting forever');
      expect(follows.users!.where((user) => user.screenName == null), isEmpty,
          reason: 'Each account in the list should keep its handle across the isolate hop');
    });

    test('Should bring a profile back with its screen name', () async {
      final profile = await firstUsable<Profile>(
          'UserByScreenName',
          (body) => parseOffThread<Profile>(body, ParseJob.profile, extra: 'https://x.com/i/api/graphql/UserByScreenName'),
          (result) => result.user.screenName?.isNotEmpty ?? false);

      expect(profile, isNotNull,
          reason: 'The profile header and tabs key off the screen name, so it must survive the '
              'isolate hop for the recorded pages that do resolve');
    });

    test('Should bring a search page back with its chains', () async {
      final status = await firstUsable<TweetStatus>(
          'SearchTimeline',
          (body) => parseOffThread<TweetStatus>(body, ParseJob.search, extra: 'Latest'),
          (result) => result.chains.isNotEmpty);

      expect(status, isNotNull,
          reason: 'At least one recorded search page holds results; losing them across the isolate '
              'would show an empty search');
    });
  });
}
