// Probes every registered endpoint against live X. Offline by default:
//
//   QUAX_LIVE=1 flutter test test/tool/endpoint_probe_test.dart
//   QUAX_LIVE=1 QUAX_AUTHENTICATED=1 flutter test test/tool/endpoint_probe_test.dart
//
// Guest mode keeps real guest errors for operations X serves anonymously.
// Authenticated mode uses the accounts already stored in the app database and
// covers the private/scoped reads. Every request is read-only.

import 'dart:io' show Platform;
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/catcher/exceptions.dart';
import 'package:quax/client/client.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/constants.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/generated/l10n.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _userId = '971742411851317248';
const _tweetId = '2095912922601975848';

class _ProbeResult {
  const _ProbeResult(this.summary, this.itemCount);

  final String summary;
  final int itemCount;
}

class _ProbeCase {
  const _ProbeCase(
    this.run, {
    this.guestCapable = false,
    this.requireNonEmpty = true,
  });

  final Future<_ProbeResult> Function() run;
  final bool guestCapable;
  final bool requireNonEmpty;
}

final _probeCases = <String, _ProbeCase>{
  'SearchTimeline': _ProbeCase(() async {
    final result = await Twitter.searchTweets(
      'quax',
      product: 'Latest',
      limit: 5,
    );
    return _ProbeResult(
      '${result.chains.length} chain(s)',
      result.chains.length,
    );
  }),
  'HomeTimeline': _ProbeCase(() async {
    final result = await Twitter.getTimelineTweets(
      'ForYou',
      'profile',
      count: 5,
      getTweetsCounter: () => 0,
      incrementTweetsCounter: () {},
    );
    return _ProbeResult(
      '${result.chains.length} chain(s)',
      result.chains.length,
    );
  }),
  'HomeLatestTimeline': _ProbeCase(() async {
    final result = await Twitter.getHomeLatestTimeline(
      count: 5,
      getTweetsCounter: () => 0,
      incrementTweetsCounter: () {},
    );
    return _ProbeResult(
      '${result.chains.length} chain(s)',
      result.chains.length,
    );
  }),
  'UserByRestId': _ProbeCase(() async {
    final profile = await Twitter.getProfileById(_userId);
    return _ProbeResult('@${profile.user.screenName}', 1);
  }),
  'UserByScreenName': _ProbeCase(() async {
    final profile = await Twitter.getProfileByScreenName('quax_tests');
    return _ProbeResult('@${profile.user.screenName}', 1);
  }, guestCapable: true),
  'Following': _ProbeCase(() async {
    final result = await Twitter.friendsList(_userId, 5);
    return _ProbeResult(
      '${result.users?.length ?? 0} user(s)',
      result.users?.length ?? 0,
    );
  }),
  'Followers': _ProbeCase(() async {
    final result = await Twitter.followersList(_userId, 5);
    return _ProbeResult(
      '${result.users?.length ?? 0} user(s)',
      result.users?.length ?? 0,
    );
  }),
  'TweetDetail': _ProbeCase(() async {
    final result = await Twitter.getTweet(_tweetId);
    return _ProbeResult(
      '${result.chains.length} chain(s)',
      result.chains.length,
    );
  }),
  'Likes': _ProbeCase(() async {
    final result = await Twitter.getLikes(
      _userId,
      count: 5,
      getTweetsCounter: () => 0,
      incrementTweetsCounter: () {},
    );
    return _ProbeResult(
      '${result.chains.length} chain(s)',
      result.chains.length,
    );
  }, requireNonEmpty: false),
  'Bookmarks': _ProbeCase(() async {
    final result = await Twitter.getBookmarks(
      count: 5,
      getTweetsCounter: () => 0,
      incrementTweetsCounter: () {},
    );
    return _ProbeResult(
      '${result.chains.length} chain(s)',
      result.chains.length,
    );
  }, requireNonEmpty: false),
  'UserVideoTimeline': _ProbeCase(() async {
    final result = await Twitter.getTweets(
      _userId,
      'media',
      const [],
      count: 5,
      getTweetsCounter: () => 0,
      incrementTweetsCounter: () {},
    );
    return _ProbeResult(
      '${result.chains.length} chain(s)',
      result.chains.length,
    );
  }),
  'UserMedia': _ProbeCase(() async {
    final result = await Twitter.getTweets(
      _userId,
      'photos',
      const [],
      count: 5,
      getTweetsCounter: () => 0,
      incrementTweetsCounter: () {},
    );
    return _ProbeResult(
      '${result.chains.length} chain(s)',
      result.chains.length,
    );
  }),
  'UserRepliesTimeline': _ProbeCase(() async {
    final result = await Twitter.getTweets(
      _userId,
      'profile',
      const [],
      count: 5,
      getTweetsCounter: () => 0,
      incrementTweetsCounter: () {},
    );
    return _ProbeResult(
      '${result.chains.length} chain(s)',
      result.chains.length,
    );
  }),
  'UserOriginalsTimeline': _ProbeCase(() async {
    final result = await Twitter.getTweets(
      _userId,
      'profile',
      const [],
      count: 5,
      includeReplies: false,
      getTweetsCounter: () => 0,
      incrementTweetsCounter: () {},
    );
    return _ProbeResult(
      '${result.chains.length} chain(s)',
      result.chains.length,
    );
  }),
};

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final live = Platform.environment['QUAX_LIVE'] == '1';
  final authenticated = Platform.environment['QUAX_AUTHENTICATED'] == '1';

  setUpAll(() async {
    await Repository().migrate();
    await L10n.load(const Locale('en'));
    if (live && authenticated && (await getAccounts()).isEmpty) {
      fail('QUAX_AUTHENTICATED=1 requires an account in the app database');
    }
  });

  test('Should keep live probe cases in parity with the endpoint registry', () {
    expect(
      _probeCases.keys,
      unorderedEquals(graphQlEndpoints.keys),
      reason:
          'Every registered operation must be probed; a missing case lets a rotated queryId '
          'ship unnoticed',
    );
  });

  test(
    'Should report a guest HTTP status without calling it a parse failure',
    () {
      final message = _message(
        'UserByScreenName',
        NoAccountAvailableException(statusCode: 401),
      );

      expect(message, contains('HTTP 401'));
      expect(
        message,
        isNot(contains('HTTP 200 with a parse failure')),
        reason: 'A rejected guest request is an HTTP failure, not a moved response shape',
      );
    },
  );

  for (final entry in _probeCases.entries) {
    test('endpoint ${entry.key}', () async {
      if (!live) {
        // ignore: avoid_print
        print('SKIP ${entry.key} — set QUAX_LIVE=1 to probe live X');
        return;
      }
      if (!authenticated && !entry.value.guestCapable) {
        // ignore: avoid_print
        print('SKIP ${entry.key} — needs a session; set QUAX_AUTHENTICATED=1');
        return;
      }

      final sw = Stopwatch()..start();
      try {
        final result = await entry.value.run();
        sw.stop();
        if (entry.value.requireNonEmpty) {
          expect(
            result.itemCount,
            greaterThan(0),
            reason:
                '${entry.key} returned its expected root but no usable items; the response '
                'shape may have moved while still answering HTTP 200',
          );
        }
        // ignore: avoid_print
        print(
          'OK   ${entry.key.padRight(24)} ${result.summary} in ${sw.elapsedMilliseconds} ms',
        );
      } catch (error) {
        sw.stop();
        fail(_message(entry.key, error));
      }
    }, timeout: const Timeout(Duration(seconds: 45)));
  }
}

String _message(String operation, Object error) {
  final text = error.toString();
  final exceptionStatus = error is NoAccountAvailableException
      ? error.statusCode
      : null;
  final status =
      exceptionStatus?.toString() ??
      RegExp(r'(?:code|statusCode)[=:]\s*(\d+)').firstMatch(text)?.group(1);
  final endpoint = graphQlEndpoints[operation]!;

  final buffer = StringBuffer(
    '$operation failed (${endpoint.method} ${endpoint.path})',
  );
  if (status != null) buffer.write(' with HTTP $status');
  buffer.writeln('\n');
  buffer.writeln(text.split('\n').take(3).join('\n'));

  if (exceptionStatus != null) {
    buffer.write(
      '\nNo usable account was available and the guest request failed with HTTP $exceptionStatus. '
      'Re-run with QUAX_AUTHENTICATED=1 to probe this operation with a stored session.',
    );
  } else if (status == '404' || text.contains('NoWorkingAccount')) {
    buffer.write(
      "\nX rotated this operation's queryId. Update the endpoint registry from a fresh "
      'capture, or re-record with tool/record/.',
    );
  } else if (status == '429' || text.contains('RateLimited')) {
    buffer.write(
      '\nRate-limited. Re-run later, or record with tool/record/ and a real session.',
    );
  } else if (text.contains('Timeout') || text.contains('SocketException')) {
    buffer.write('\nNo answer from X. Check the connection, then re-run.');
  } else {
    buffer.write(
      '\nHTTP 200 with a parse failure means the response shape moved. Compare the '
      'fixtures in test/fixtures/ and re-record if needed.',
    );
  }
  return buffer.toString();
}
