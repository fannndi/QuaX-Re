import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:quax/catcher/exceptions.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/client.dart';
import 'package:quax/client/client_regular_account.dart';
import 'package:quax/client/client_unauthenticated.dart';
import 'package:quax/client/headers.dart';
import 'package:quax/client/rate_limit_tracker.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    databaseName = 'quax_request_policy_test.db';
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await deleteDatabase(databaseName);
    await Repository().migrate();
    RateLimitTracker.clearForTests();
    TwitterHeaders.resetForTests();
    XRegularAccount.debugFetchOverride = null;
    activeAccount.value = null;
    accountsRevision.value = 0;
  });

  tearDown(() async {
    XRegularAccount.debugFetchOverride = null;
    activeAccount.value = null;
    accountsRevision.value = 0;
    await deleteDatabase(databaseName);
  });

  Future<void> insertAccount(
    String id, {
    String? screenName,
    String? userId,
    bool isActive = false,
    DateTime? lastNotFoundAt,
    DateTime? lastAuthErrorAt,
    String? cookie,
  }) async {
    final database = await Repository.writable();
    await database.insert(
      tableAccounts,
      Account(
        id: id,
        authHeader: jsonEncode({'Cookie': 'auth_token=${cookie ?? id}'}),
        screenName: screenName ?? id,
        userId: userId,
        isActive: isActive,
        lastNotFoundAt: lastNotFoundAt,
        lastAuthErrorAt: lastAuthErrorAt,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  group('request coalescing', () {
    test('Should not share a response across an account switch', () {
      final uri = Uri.parse('https://x.com/i/api/graphql/x/HomeTimeline');

      activeAccount.value = const ActiveAccount(id: 'A');
      final first = requestCoalescingKey(uri);

      activeAccount.value = const ActiveAccount(id: 'B');
      accountsRevision.value++;

      expect(requestCoalescingKey(uri), isNot(first),
          reason: 'A new login asking for the same URI must not join the previous '
              'login\'s in-flight response; doing so shows the old feed after a switch');
    });

    test('Should keep the same key when only the numeric user id is filled in', () {
      final uri = Uri.parse('https://x.com/i/api/graphql/x/Likes');

      activeAccount.value = const ActiveAccount(id: 'A');
      final before = requestCoalescingKey(uri);

      activeAccount.value = const ActiveAccount(id: 'A', userId: '42');

      expect(requestCoalescingKey(uri), before,
          reason: 'setActiveAccountUserId does not change which session sends the request, '
              'so an identical load can still share the response');
    });

    test('Should not share a scoped and an unscoped request', () {
      final uri = Uri.parse('https://x.com/i/api/graphql/x/HomeTimeline');
      activeAccount.value = const ActiveAccount(id: 'A');

      expect(requestCoalescingKey(uri, accountScoped: true), isNot(requestCoalescingKey(uri)),
          reason: 'A scoped read must never join an unscoped request and skip the account '
              'pre-check; the two have different failure rules');
    });
  });

  group('account-scoped requests', () {
    test('Should keep a scoped read on the active account', () async {
      await insertAccount('A', isActive: true);
      await insertAccount('B');
      final seen = <String>[];

      XRegularAccount.debugFetchOverride =
          (uri, {headers, body, required log, required authHeader}) async {
        seen.add(authHeader['Cookie'] as String);
        return http.Response('{}', 200);
      };

      final response = await Twitter.debugFetch(
        Uri.parse('https://x.com/i/api/graphql/x/Bookmarks'),
        accountScoped: true,
      );

      expect(response.statusCode, 200,
          reason: 'Bookmarks must be fetched as the active account, not as another login');
      expect(seen, ['auth_token=A'],
          reason: 'The health selector must not rotate a private read to account B');
    });

    test('Should fail rather than rotate when the active account is rate limited', () async {
      await insertAccount('A', isActive: true);
      await insertAccount('B');
      RateLimitTracker.flag('A', '/i/api/graphql/x/Bookmarks', DateTime.now().add(const Duration(minutes: 10)));

      XRegularAccount.debugFetchOverride =
          (uri, {headers, body, required log, required authHeader}) async {
        return http.Response('{}', 200);
      };

      await expectLater(
        Twitter.debugFetch(
          Uri.parse('https://x.com/i/api/graphql/x/Bookmarks'),
          accountScoped: true,
        ),
        throwsA(isA<RateLimitedException>()),
        reason: 'A scoped read must surface the limit on the chosen account instead of '
            'quietly using another login',
      );
    });

    test('Should not spend another request on a session X already rejected', () async {
      await insertAccount('A', isActive: true);
      var calls = 0;

      XRegularAccount.debugFetchOverride =
          (uri, {headers, body, required log, required authHeader}) async {
        calls++;
        return http.Response('{}', 401);
      };

      final uri = Uri.parse('https://x.com/i/api/graphql/x/Bookmarks');
      await expectLater(Twitter.debugFetch(uri, accountScoped: true),
          throwsA(isA<NoWorkingAccountException>()));
      await expectLater(Twitter.debugFetch(uri, accountScoped: true),
          throwsA(isA<NoWorkingAccountException>()));

      expect(calls, 1,
          reason: 'Once X answers 401 the session is known to be dead; repeating the request '
              'wastes a round-trip and hides the re-login action behind another error');
    });

    test('Should not rotate the Following timeline to another account', () async {
      await insertAccount('A', isActive: true, lastAuthErrorAt: DateTime.now());
      await insertAccount('B');
      var calls = 0;

      XRegularAccount.debugFetchOverride =
          (uri, {headers, body, required log, required authHeader}) async {
        calls++;
        return http.Response('{}', 200);
      };

      await expectLater(
        Twitter.getHomeLatestTimeline(
          getTweetsCounter: () => 20,
          incrementTweetsCounter: () {},
          resetTweetsCounter: () {},
        ),
        throwsA(isA<NoWorkingAccountException>()),
        reason: 'The chronological feed belongs to the chosen login; rotating to B would show a '
            'different reader\'s follows under A\'s account button',
      );
      expect(calls, 0,
          reason: 'An expired active session should fail before a request is sent');
    });
  });

  group('account retry policy', () {
    test('Should try a flagged account after two sessions are rejected', () async {
      await insertAccount('A', isActive: true);
      await insertAccount('B');
      await insertAccount('C', lastNotFoundAt: DateTime.now());
      final seen = <String>[];

      XRegularAccount.debugFetchOverride =
          (uri, {headers, body, required log, required authHeader}) async {
        final cookie = authHeader['Cookie'] as String;
        seen.add(cookie);
        if (cookie == 'auth_token=C') return http.Response('{}', 200);
        return http.Response('{}', 401);
      };

      final response = await Twitter.debugFetch(
        Uri.parse('https://x.com/i/api/graphql/x/Bookmarks'),
      );

      expect(response.statusCode, 200,
          reason: 'A working account must still be tried after two sessions are rejected');
      expect(seen, hasLength(3),
          reason: 'The old cap stopped after two auth failures and never reached the third account');
      expect(seen.last, 'auth_token=C');
    });

    test('Should report no working account when every account answers 401', () async {
      await insertAccount('A', isActive: true);
      await insertAccount('B');

      XRegularAccount.debugFetchOverride =
          (uri, {headers, body, required log, required authHeader}) async {
        return http.Response('{}', 401);
      };

      await expectLater(
        Twitter.debugFetch(Uri.parse('https://x.com/i/api/graphql/x/SearchTimeline')),
        throwsA(isA<NoWorkingAccountException>()),
        reason: 'Search is not account-scoped, but once every login was rejected the UI still '
            'needs the re-login action instead of a generic 401 error page',
      );
    });

    test('Should rotate away from a session flagged by an earlier 401', () async {
      await insertAccount('A', isActive: true);
      await insertAccount('B');
      final seen = <String>[];

      XRegularAccount.debugFetchOverride =
          (uri, {headers, body, required log, required authHeader}) async {
        final cookie = authHeader['Cookie'] as String;
        seen.add(cookie);
        return cookie == 'auth_token=A' ? http.Response('{}', 401) : http.Response('{}', 200);
      };

      final uri = Uri.parse('https://x.com/i/api/graphql/x/SearchTimeline');
      await Twitter.debugFetch(uri);
      seen.clear();
      await Twitter.debugFetch(uri);

      expect(seen, ['auth_token=B'],
          reason: 'A login that already answered 401 should not be the first choice for the next '
              'public request; the selector has a healthy account available');
    });
  });

  group('403 transaction-id recovery', () {
    test('Should re-derive the header once and retry the same account', () async {
      await insertAccount('A', isActive: true);
      var calls = 0;

      XRegularAccount.debugFetchOverride =
          (uri, {headers, body, required log, required authHeader}) async {
        calls++;
        return calls == 1 ? http.Response('', 403) : http.Response('{}', 200);
      };

      final response = await Twitter.debugFetch(
        Uri.parse('https://x.com/i/api/graphql/x/HomeLatestTimeline'),
      );

      expect(response.statusCode, 200,
          reason: '403 means the transaction key is wrong; re-deriving it once should recover');
      expect(calls, 2,
          reason: 'The retry must go to the same account, not be lost by rotating away from it');
    });

    test('Should surface a repeated 403 after one retry', () async {
      await insertAccount('A', isActive: true);
      var calls = 0;

      XRegularAccount.debugFetchOverride =
          (uri, {headers, body, required log, required authHeader}) async {
        calls++;
        return http.Response('', 403);
      };

      final response = await Twitter.debugFetch(
        Uri.parse('https://x.com/i/api/graphql/x/HomeLatestTimeline'),
      );

      expect(response.statusCode, 403,
          reason: 'A second 403 with a fresh header means the request really is forbidden');
      expect(calls, 2, reason: 'Only one retry is allowed, so a broken page cannot retry forever');
    });
  });

  group('guest token budget', () {
    test('Should reject an exhausted token', () {
      expect(guestTokenUsable(nowMs: 1000, expiresAt: 2000, remaining: 0), isFalse,
          reason: 'remaining < limit was true for an exhausted token, so every guest request '
              'kept reusing it until the window reset');
    });

    test('Should accept a token with budget left', () {
      expect(guestTokenUsable(nowMs: 1000, expiresAt: 2000, remaining: 1), isTrue);
    });

    test('Should reject a token past its reset time', () {
      expect(guestTokenUsable(nowMs: 3000, expiresAt: 2000, remaining: 1), isFalse);
    });

    test('Should accept an unknown window', () {
      expect(guestTokenUsable(nowMs: 1000, expiresAt: -1, remaining: -1), isTrue,
          reason: 'No endpoint has reported a window yet; the fresh token is still usable');
    });
  });

  group('account identity writes', () {
    test('Should replace the old row when the same handle logs in again', () async {
      await saveLoggedInAccount(id: 'ct0-1', screenName: 'alice', userId: 'u1', authHeader: '{}');
      await saveLoggedInAccount(id: 'ct0-2', screenName: 'alice', userId: 'u1', authHeader: '{}');

      final accounts = await getAccounts();

      expect(accounts, hasLength(1),
          reason: 'A new ct0 on re-login used to leave the old row behind as a second account');
      expect(accounts.single.id, 'ct0-2',
          reason: 'The fresh session must be the row that survives');
    });

    test('Should keep two different handles as two accounts', () async {
      await saveLoggedInAccount(id: 'ct0-1', screenName: 'alice', authHeader: '{}');
      await saveLoggedInAccount(id: 'ct0-2', screenName: 'bob', authHeader: '{}');

      expect(await getAccounts(), hasLength(2));
    });

    test('Should publish the switch when the last account is deleted', () async {
      activeAccount.value = const ActiveAccount(id: 'A');
      accountsRevision.value = 0;

      await promoteFirstAccountIfNoneActive();

      expect(activeAccount.value, isNull);
      expect(accountsRevision.value, 1,
          reason: 'Feeds and private tabs listen to the revision; without a bump they keep '
              'showing the deleted account\'s content');
    });
  });

  group('defensive count parsing', () {
    test('Should accept string, integer and decimal counts', () {
      expect(parseIntLike('25436'), 25436);
      expect(parseIntLike(25436), 25436);
      expect(parseIntLike(25436.9), 25436);
      expect(parseIntLike(null), isNull);
      expect(parseIntLike('not a number'), isNull);
    });
  });
}
