// Probes every endpoint the app reads against live X and reports which ones
// answer. Not part of `flutter test`'s normal run — it needs the network, and
// X's answers are the thing under test, so it is opt-in:
//
//   flutter test test/tool/endpoint_probe_test.dart --plain-name "endpoint"
//
// It has to live under test/ rather than tool/ because the client imports
// Flutter (`dart:ui`), and `dart run` cannot load that outside a binding.
//
// What it answers that check_indices cannot:
//
//   • which queryIds have rotated. A GraphQL path is version-pinned
//     (`/i/api/graphql/<queryId>/<Operation>`); when X rotates one the app gets
//     a 404 for that one operation while every other keeps working. The fork
//     notes say to update the constant, and this says which constant.
//   • whether a response is still the shape the fixtures pin. An endpoint that
//     answers 200 with a moved key (`data.user.result` gone) breaks the parser
//     just as silently as a 404 does.
//
// Guest requests only: no account, no cookies, nothing sent. Everything the app
// asks for is a read.
@Tags(['live'])
library;

import 'dart:io' show Platform;
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/client.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/generated/l10n.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  // The client asks the repository for accounts before every request, so the
  // database has to exist even though this test reads nothing from it.
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUpAll(() async {
    await Repository().migrate();
    await L10n.load(const Locale('en'));
  });

  // Each operation with the argument it needs, so the report names the endpoint
  // that failed rather than a stack trace. An endpoint missing from here is an
  // endpoint nobody notices breaking.
  final cases = <String, Future<Object?> Function()>{
    'SearchTimeline': () async {
      final r = await Twitter.searchTweets('quax', product: 'Latest', limit: 5);
      return '${r.chains.length} chain(s)';
    },
    'HomeTimeline': () async {
      final r = await Twitter.getTimelineTweets('1', 'profile',
          count: 5, getTweetsCounter: () => 0, incrementTweetsCounter: () {});
      return '${r.chains.length} chain(s)';
    },
    'HomeLatestTimeline': () async {
      final r = await Twitter.getHomeLatestTimeline(
          count: 5, getTweetsCounter: () => 0, incrementTweetsCounter: () {});
      return '${r.chains.length} chain(s)';
    },
    'UserByScreenName': () async {
      final p = await Twitter.getProfileByScreenName('quax_tests');
      return '@${p.user.screenName}';
    },
    'UserTweets': () async {
      final r = await Twitter.getTweets('2095909295913103360', 'profile', const [],
          count: 5, getTweetsCounter: () => 0, incrementTweetsCounter: () {});
      return '${r.chains.length} chain(s)';
    },
    'TweetDetail': () async {
      final r = await Twitter.getTweet('2095912922601975848');
      return '${r.chains.length} chain(s)';
    },
    'Likes': () async {
      final r = await Twitter.getLikes('2095909295913103360',
          count: 5, getTweetsCounter: () => 0, incrementTweetsCounter: () {});
      return '${r.chains.length} chain(s)';
    },
    'Bookmarks': () async {
      final r = await Twitter.getBookmarks(
          count: 5, getTweetsCounter: () => 0, incrementTweetsCounter: () {});
      return '${r.chains.length} chain(s)';
    },
  };

  // Which operations X answers without a session. Everything else needs one:
  // "No account available" is the client's answer for both "this endpoint needs
  // a login" and "the guest request also failed", so a probe that treats that
  // as a failure reports seven broken endpoints when nothing is broken. These
  // are covered by tool/record/, which has a real session.
  const guestCapable = <String>{
    'UserByScreenName',
  };

  for (final entry in cases.entries) {
    test('endpoint ${entry.key}', () async {
      // Offline by default. `flutter test` must never touch the network, so the
      // probe skips unless it is asked for explicitly:
      //
      //   QUAX_LIVE=1 flutter test test/tool/endpoint_probe_test.dart
      //
      // A tag would be the usual mechanism, but the test runner has no
      // "exclude by default" switch, so a plain `flutter test` would run it.
      final live = Platform.environment['QUAX_LIVE'] == '1';
      if (!live) {
        // ignore: avoid_print
        print('SKIP ${entry.key} — set QUAX_LIVE=1 to probe live X');
        return;
      }

      final sw = Stopwatch()..start();
      Object? summary;
      try {
        summary = await entry.value();
      } catch (e) {
        sw.stop();
        if (!guestCapable.contains(entry.key)) {
          // ignore: avoid_print
          print('SKIP ${entry.key} — needs a session; cover it with tool/record/');
          return;
        }
        fail(_message(entry.key, e));
      }
      sw.stop();
      // Not an assertion about behaviour — a report. The value is only useful
      // in the output, so print it rather than assert on a shape that X may
      // legitimately change.
      // ignore: avoid_print
      print('OK   ${entry.key.padRight(20)} $summary in ${sw.elapsedMilliseconds} ms');
      expect(summary, isNotNull,
          reason: 'Every operation should return something. A null means the '
              'client method has no result type wired up');
    }, timeout: const Timeout(Duration(seconds: 45)));
  }
}

String _message(String operation, Object error) {
  final text = error.toString();
  final status = RegExp(r'(?:code|statusCode)[=:]\s*(\d+)').firstMatch(text)?.group(1);

  final buffer = StringBuffer('$operation failed');
  if (status != null) buffer.write(' with HTTP $status');
  buffer.writeln();
  buffer.writeln();

  // The raw error first: "HTTP 404" is a guess about the cause, but
  // `type 'bool' is not a subtype of type 'String'` is the actual parse failure
  // and says far more about what moved.
  buffer.writeln(text.split('\n').take(3).join('\n'));
  buffer.writeln();

  if (status == '404' || text.contains('NoWorkingAccount')) {
    buffer.writeln("X rotated this operation's queryId. Capture the new one from the network tab of "
        'a x.com visit and update the constant in client.dart, or re-record with tool/record/.');
  } else if (status == '429' || text.contains('RateLimited')) {
    buffer.writeln('Rate-limited as a guest. Re-run later, or record with tool/record/, which uses '
        'a real session.');
  } else if (text.contains('Timeout') || text.contains('SocketException')) {
    buffer.writeln('No answer from X. Check the connection, then re-run.');
  } else {
    buffer.writeln('If the status was 200 but the parse threw, the response shape moved and the '
        'fixtures in test/fixtures/ need re-recording.');
  }

  return buffer.toString();
}
