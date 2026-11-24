import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:quax/catcher/exceptions.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/client.dart';
import 'package:quax/client/client_regular_account.dart';
import 'package:quax/client/client_unauthenticated.dart';
import 'package:quax/client/headers.dart';
import 'package:quax/client/http_client.dart';
import 'package:quax/client/rate_limit_tracker.dart';
import 'package:quax/client/session_crypto.dart';
import 'package:quax/constants.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/utils/network_status.dart';
import 'package:quax/utils/timeline_cache.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..connectionTimeout = const Duration(seconds: 1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    databaseName = 'quax_request_policy_test.db';
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SessionCrypto.debugOverride = (method, arguments) async {
      final text = arguments['text'] as String;
      if (method == 'encryptSession') {
        return '${SessionCrypto.encryptedPrefix}${base64Url.encode(utf8.encode(text))}';
      }
      final encoded = text.startsWith(SessionCrypto.encryptedPrefix)
          ? text.substring(SessionCrypto.encryptedPrefix.length)
          : text;
      return utf8.decode(base64Url.decode(encoded));
    };
    await deleteDatabase(databaseName);
    await Repository().migrate();
    RateLimitTracker.clearForTests();
    TwitterHeaders.resetForTests();
    XRegularAccount.debugFetchOverride = null;
    debugAccountsReader = null;
    debugGuestFetchOverride = null;
    activeAccount.value = null;
    accountsRevision.value = 0;
  });

  tearDown(() async {
    SessionCrypto.debugOverride = null;
    XRegularAccount.debugFetchOverride = null;
    debugAccountsReader = null;
    debugGuestFetchOverride = null;
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
    String? authHeader,
  }) async {
    final database = await Repository.writable();
    await database.insert(
      tableAccounts,
      Account(
        id: id,
        authHeader:
            authHeader ?? jsonEncode({'Cookie': 'auth_token=${cookie ?? id}'}),
        screenName: screenName ?? id,
        userId: userId,
        isActive: isActive,
        lastNotFoundAt: lastNotFoundAt,
        lastAuthErrorAt: lastAuthErrorAt,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  group('NetworkStatus probe seam', () {
    test('Should cache an injected HTTPS probe result', () async {
      var calls = 0;
      final status = NetworkStatus.withProbe(() async {
        calls++;
        return true;
      }, cacheFor: const Duration(minutes: 1))..online.addListener(() {});
      addTearDown(status.dispose);

      expect(await status.check(), isTrue);
      expect(await status.check(), isTrue);
      expect(
        calls,
        1,
        reason:
            'Screens ask freely; a successful bounded probe should be cached instead of '
            'opening a new TLS connection for every widget build',
      );
    });

    test('Should recover when a forced re-probe succeeds', () async {
      var reachable = false;
      final status = NetworkStatus.withProbe(
        () async => reachable,
        cacheFor: Duration.zero,
        probeInterval: const Duration(hours: 1),
      )..online.addListener(() {});
      addTearDown(status.dispose);

      expect(
        await status.check(force: true),
        isFalse,
        reason: 'A failed HTTPS/TCP probe with no DNS answer means offline',
      );
      reachable = true;
      expect(
        await status.check(force: true),
        isTrue,
        reason: 'The periodic seam must be able to flip online back without restarting the app',
      );
      expect(status.online.value, isTrue);
    });
  });

  group('HTTP timeout', () {
    test('Should abort the underlying request instead of only timing out the future', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      await HttpOverrides.runWithHttpOverrides(() async {
        final client = TimeoutHttpClient(
          timeout: const Duration(milliseconds: 50),
        );
        try {
          await expectLater(
            client.get(
              Uri.parse('http://${server.address.host}:${server.port}/stall'),
            ),
            throwsA(isA<http.RequestAbortedException>()),
            reason:
                'A future timeout alone leaves the socket alive; the HTTP layer must abort the '
                'request so repeated failures do not leak connections',
          );
        } finally {
          client.close();
        }
      }, _RealHttpOverrides());
      await server.close(force: true);
    });
    test('Should cancel an externally aborted production read', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      await HttpOverrides.runWithHttpOverrides(() async {
        final client = TimeoutHttpClient();
        final abort = Completer<void>();
        try {
          final pending = client.readWithAbort(
            Uri.parse('http://${server.address.host}:${server.port}/stall'),
            abortTrigger: abort.future,
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          abort.complete();
          await expectLater(
            pending,
            throwsA(isA<http.RequestAbortedException>()),
            reason: 'Transaction deadlines must abort the underlying socket, not only stop waiting',
          );
        } finally {
          client.close();
        }
      }, _RealHttpOverrides());
      await server.close(force: true);
    });
  });

  group('request coalescing', () {
    test('Should not share a response across an account switch', () {
      final uri = Uri.parse('https://x.com/i/api/graphql/x/HomeTimeline');

      activeAccount.value = const ActiveAccount(id: 'A');
      final first = requestCoalescingKey(uri);

      activeAccount.value = const ActiveAccount(id: 'B');
      accountsRevision.value++;

      expect(
        requestCoalescingKey(uri),
        isNot(first),
        reason:
            'A new login asking for the same URI must not join the previous '
            'login\'s in-flight response; doing so shows the old feed after a switch',
      );
    });

    test(
      'Should keep the same key when only the numeric user id is filled in',
      () {
        final uri = Uri.parse('https://x.com/i/api/graphql/x/Likes');

        activeAccount.value = const ActiveAccount(id: 'A');
        final before = requestCoalescingKey(uri);

        activeAccount.value = const ActiveAccount(id: 'A', userId: '42');

        expect(
          requestCoalescingKey(uri),
          before,
          reason:
              'setActiveAccountUserId does not change which session sends the request, '
              'so an identical load can still share the response',
        );
      },
    );

    test('Should not share a scoped and an unscoped request', () {
      final uri = Uri.parse('https://x.com/i/api/graphql/x/HomeTimeline');
      activeAccount.value = const ActiveAccount(id: 'A');

      expect(
        requestCoalescingKey(uri, accountScoped: true),
        isNot(requestCoalescingKey(uri)),
        reason:
            'A scoped read must never join an unscoped request and skip the account '
            'pre-check; the two have different failure rules',
      );
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

      expect(
        response.statusCode,
        200,
        reason: 'Bookmarks must be fetched as the active account, not as another login',
      );
      expect(
        seen,
        ['auth_token=A'],
        reason:
            'The health selector must not rotate a private read to account B',
      );
    });

    test('Should keep the account captured by a scoped coalescing key across a switch', () async {
      await insertAccount('A', isActive: true);
      await insertAccount('B');
      activeAccount.value = const ActiveAccount(id: 'A');
      final accountsRead = Completer<List<Account>>();
      debugAccountsReader = () => accountsRead.future;
      final seen = <String>[];
      XRegularAccount.debugFetchOverride =
          (uri, {headers, body, required log, required authHeader}) async {
            seen.add(authHeader['Cookie'] as String);
            return http.Response(
              jsonEncode({
                'data': {
                  'bookmark_timeline_v2': {
                    'timeline': {'instructions': []},
                  },
                },
              }),
              200,
            );
          };

      final key = requestCoalescingKey(
        Uri.parse('https://x.com/i/api/graphql/x/Bookmarks'),
        accountScoped: true,
      );
      final pending = Twitter.getBookmarks(
        count: 5,
        getTweetsCounter: () => 0,
        incrementTweetsCounter: () {},
      );
      // The SQLite read is deliberately paused, reproducing a switch between
      // coalescing-key creation and account selection.
      activeAccount.value = const ActiveAccount(id: 'B');
      accountsRevision.value++;
      final database = await Repository.writable();
      await database.transaction((txn) async {
        await txn.update(
          tableAccounts,
          {'is_active': 0},
          where: 'id = ?',
          whereArgs: ['A'],
        );
        await txn.update(
          tableAccounts,
          {'is_active': 1},
          where: 'id = ?',
          whereArgs: ['B'],
        );
      });
      accountsRead.complete(await getAccounts());

      await pending;

      expect(
        key,
        startsWith('A\u0000'),
        reason: 'The in-flight scoped request belongs to the account active when its key was made',
      );
      expect(
        seen,
        ['auth_token=A'],
        reason:
            'A switch while the account read is in flight must not execute an A-keyed private '
            'request with B\'s session',
      );
    });

    test(
      'Should fail rather than rotate when the active account is rate limited',
      () async {
        await insertAccount('A', isActive: true);
        await insertAccount('B');
        RateLimitTracker.flag(
          'A',
          '/i/api/graphql/x/Bookmarks',
          DateTime.now().add(const Duration(minutes: 10)),
        );

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
          reason:
              'A scoped read must surface the limit on the chosen account instead of '
              'quietly using another login',
        );
      },
    );

    test(
      'Should not spend another request on a session X already rejected',
      () async {
        await insertAccount('A', isActive: true);
        var calls = 0;

        XRegularAccount.debugFetchOverride =
            (uri, {headers, body, required log, required authHeader}) async {
              calls++;
              return http.Response('{}', 401);
            };

        final uri = Uri.parse('https://x.com/i/api/graphql/x/Bookmarks');
        await expectLater(
          Twitter.debugFetch(uri, accountScoped: true),
          throwsA(isA<NoWorkingAccountException>()),
        );
        await expectLater(
          Twitter.debugFetch(uri, accountScoped: true),
          throwsA(isA<NoWorkingAccountException>()),
        );

        expect(
          calls,
          1,
          reason:
              'Once X answers 401 the session is known to be dead; repeating the request '
              'wastes a round-trip and hides the re-login action behind another error',
        );
      },
    );

    test(
      'Should not rotate the Following timeline to another account',
      () async {
        await insertAccount(
          'A',
          isActive: true,
          lastAuthErrorAt: DateTime.now(),
        );
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
          reason:
              'The chronological feed belongs to the chosen login; rotating to B would show a '
              'different reader\'s follows under A\'s account button',
        );
        expect(
          calls,
          0,
          reason:
              'An expired active session should fail before a request is sent',
        );
      },
    );
  });

  group('account retry policy', () {
    test(
      'Should try a flagged account after two sessions are rejected',
      () async {
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

        expect(
          response.statusCode,
          200,
          reason: 'A working account must still be tried after two sessions are rejected',
        );
        expect(
          seen,
          hasLength(3),
          reason: 'The old cap stopped after two auth failures and never reached the third account',
        );
        expect(seen.last, 'auth_token=C');
      },
    );

    test(
      'Should report no working account when every account answers 401',
      () async {
        await insertAccount('A', isActive: true);
        await insertAccount('B');

        XRegularAccount.debugFetchOverride =
            (uri, {headers, body, required log, required authHeader}) async {
              return http.Response('{}', 401);
            };

        await expectLater(
          Twitter.debugFetch(
            Uri.parse('https://x.com/i/api/graphql/x/SearchTimeline'),
          ),
          throwsA(isA<NoWorkingAccountException>()),
          reason:
              'Search is not account-scoped, but once every login was rejected the UI still '
              'needs the re-login action instead of a generic 401 error page',
        );
      },
    );

    test(
      'Should rotate away from a session flagged by an earlier 401',
      () async {
        await insertAccount('A', isActive: true);
        await insertAccount('B');
        final seen = <String>[];

        XRegularAccount.debugFetchOverride =
            (uri, {headers, body, required log, required authHeader}) async {
              final cookie = authHeader['Cookie'] as String;
              seen.add(cookie);
              return cookie == 'auth_token=A'
                  ? http.Response('{}', 401)
                  : http.Response('{}', 200);
            };

        final uri = Uri.parse('https://x.com/i/api/graphql/x/SearchTimeline');
        await Twitter.debugFetch(uri);
        seen.clear();
        await Twitter.debugFetch(uri);

        expect(
          seen,
          ['auth_token=B'],
          reason:
              'A login that already answered 401 should not be the first choice for the next '
              'public request; the selector has a healthy account available',
        );
      },
    );
    test('Should exclude a malformed auth header and continue to a healthy account', () async {
      await insertAccount('A', isActive: true, authHeader: 'not-json');
      await insertAccount('B', authHeader: '["not", "a", "header"]');
      await insertAccount('C', cookie: 'C');
      final seen = <String>[];

      XRegularAccount.debugFetchOverride =
          (uri, {headers, body, required log, required authHeader}) async {
            seen.add(authHeader['Cookie'] as String);
            return http.Response('{}', 200);
          };

      final response = await Twitter.debugFetch(
        Uri.parse('https://x.com/i/api/graphql/x/SearchTimeline'),
      );

      expect(
        response.statusCode,
        200,
        reason: 'A corrupt database row must not spend the network retry budget or hide a healthy login',
      );
      expect(
        seen,
        ['auth_token=C'],
        reason: 'Neither invalid JSON nor a JSON array is an auth header; both rows must be excluded',
      );
    });

    test(
      'Should fail a scoped read when the active auth header is malformed',
      () async {
        await insertAccount('A', isActive: true, authHeader: '{"Cookie": 42}');
        var calls = 0;
        XRegularAccount.debugFetchOverride =
            (uri, {headers, body, required log, required authHeader}) async {
              calls++;
              return http.Response('{}', 200);
            };

        await expectLater(
          Twitter.debugFetch(
            Uri.parse('https://x.com/i/api/graphql/x/Bookmarks'),
            accountScoped: true,
          ),
          throwsA(isA<NoWorkingAccountException>()),
          reason: 'A scoped private read must not rotate or send non-string header values',
        );
        expect(calls, 0, reason: 'Header validation happens before transport');
      },
    );

    test(
      'Should keep a successful response when the health write fails',
      () async {
        await insertAccount(
          'A',
          isActive: true,
          lastNotFoundAt: DateTime.now(),
        );
        XRegularAccount.debugFetchOverride =
            (uri, {headers, body, required log, required authHeader}) async {
              final database = await Repository.writable();
              await database.delete(tableAccounts);
              return http.Response('{}', 200);
            };

        final response = await Twitter.debugFetch(
          Uri.parse('https://x.com/i/api/graphql/x/SearchTimeline'),
        );

        expect(
          response.statusCode,
          200,
          reason: 'Health persistence is best-effort; a database write failure must not discard data X returned',
        );
      },
    );

    test('Should continue account fallback when an auth-failure health write fails', () async {
      await insertAccount('A', isActive: true);
      await insertAccount('B');
      final seen = <String>[];
      XRegularAccount.debugFetchOverride =
          (uri, {headers, body, required log, required authHeader}) async {
            final cookie = authHeader['Cookie'] as String;
            seen.add(cookie);
            if (cookie == 'auth_token=A') {
              final database = await Repository.writable();
              await database.delete(tableAccounts);
              return http.Response('{}', 401);
            }
            return http.Response('{}', 200);
          };

      final response = await Twitter.debugFetch(
        Uri.parse('https://x.com/i/api/graphql/x/SearchTimeline'),
      );

      expect(
        response.statusCode,
        200,
        reason:
            'Failure to persist A\'s 401 must not prevent B from being tried',
      );
      expect(seen, ['auth_token=A', 'auth_token=B']);
    });

    test('Should choose the same terminal status regardless of the last account tried', () async {
      await insertAccount('A', isActive: true);
      await insertAccount('B');
      var aStatus = 401;
      var bStatus = 429;
      XRegularAccount.debugFetchOverride =
          (uri, {headers, body, required log, required authHeader}) async {
            final status = authHeader['Cookie'] == 'auth_token=A'
                ? aStatus
                : bStatus;
            return http.Response('{}', status);
          };
      final uri = Uri.parse('https://x.com/i/api/graphql/x/SearchTimeline');

      expect(
        (await Twitter.debugFetch(uri)).statusCode,
        401,
        reason: 'A mixed terminal page must not be selected by whichever account happened to answer last',
      );
      aStatus = 429;
      bStatus = 401;
      RateLimitTracker.clearForTests();
      expect(
        (await Twitter.debugFetch(uri)).statusCode,
        401,
        reason: 'Reversing the statuses must still select the same deterministic terminal response',
      );
    });
  });

  group('GraphQL request contracts', () {
    String fixtureBody(String operation) {
      final folder = operation == 'HomeLatestTimeline'
          ? 'HomeTimeline'
          : operation;
      final directory = Directory('test/fixtures/$folder');
      final file = directory.listSync().whereType<File>().firstWhere(
        (file) => file.path.endsWith('.json'),
      );
      return jsonEncode(
        (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)['body'],
      );
    }

    test(
      'Should use registered methods, variables and aligned feature flags',
      () async {
        await insertAccount('A', isActive: true);
        final requests = <({String method, Uri uri, String? body})>[];
        XRegularAccount.debugFetchOverride =
            (uri, {headers, body, required log, required authHeader}) async {
              requests.add((
                method: body == null ? 'GET' : 'POST',
                uri: uri,
                body: body,
              ));
              final operation = uri.pathSegments.last;
              return http.Response.bytes(
                utf8.encode(fixtureBody(operation)),
                200,
              );
            };

        await Twitter.getTimelineTweets(
          'ForYou',
          'profile',
          count: 5,
          getTweetsCounter: () => 0,
          incrementTweetsCounter: () {},
        );
        await Twitter.getHomeLatestTimeline(
          count: 5,
          getTweetsCounter: () => 0,
          incrementTweetsCounter: () {},
        );
        await Twitter.searchTweets('quax', limit: 5);

        final home = requests[0];
        expect(
          home.method,
          'GET',
          reason: 'The 2026-11 HomeTimeline contract is GET',
        );
        expect(home.uri.path, graphQlEndpoints['HomeTimeline']!.path);
        final homeVariables = jsonDecode(
          home.uri.queryParameters['variables']!,
        ) as Map<String, dynamic>;
        expect(
          homeVariables,
          isNot(contains('latestControlAvailable')),
          reason: 'X removed this stale variable from the home contract',
        );
        final homeFeatures = jsonDecode(
          home.uri.queryParameters['features']!,
        ) as Map<String, dynamic>;
        expect(homeFeatures['post_ctas_fetch_enabled'], isTrue);
        expect(homeFeatures['x_elections_post_context_enabled'], isTrue);
        expect(homeFeatures['responsive_web_made_on_x_label_enabled'], isFalse);

        final latest = requests[1];
        expect(
          latest.method,
          'POST',
          reason: 'The 2026-11 HomeLatestTimeline contract is POST',
        );
        expect(latest.uri.path, graphQlEndpoints['HomeLatestTimeline']!.path);
        final latestBody = jsonDecode(latest.body!) as Map<String, dynamic>;
        expect(
          (latestBody['variables'] as Map<String, dynamic>)['enableRanking'],
          isFalse,
          reason: 'Following must request the chronological feed, not ranking',
        );

        final search = requests[2];
        final searchVariables = jsonDecode(
          search.uri.queryParameters['variables']!,
        ) as Map<String, dynamic>;
        expect(
          searchVariables['count'],
          5,
          reason:
              'Search count must be numeric in the current GraphQL contract',
        );
        expect(search.uri.path, graphQlEndpoints['SearchTimeline']!.path);
      },
    );
    test(
      'Should return People results together with their next cursor',
      () async {
        await insertAccount('A', isActive: true);
        Uri? requested;
        XRegularAccount.debugFetchOverride =
            (uri, {headers, body, required log, required authHeader}) async {
              requested = uri;
              final fixture = File(
                'test/fixtures/SearchTimeline/quax-677c03.json',
              );
              final body = jsonEncode(
                (jsonDecode(fixture.readAsStringSync())
                    as Map<String, dynamic>)['body'],
              );
              return http.Response.bytes(utf8.encode(body), 200);
            };

        final page = await Twitter.searchUsers(
          'quax',
          limit: 5,
          cursor: 'people-cursor',
        );

        expect(
          page.users,
          isNotEmpty,
          reason: 'The People API must return parsed users, not an empty tweet timeline',
        );
        expect(
          page.users.map((user) => user.screenName),
          everyElement(isNotEmpty),
        );
        expect(
          page.nextCursor,
          isNotNull,
          reason: 'The UI pager needs the cursor from the same People response',
        );
        final variables = jsonDecode(
          requested!.queryParameters['variables']!,
        ) as Map<String, dynamic>;
        expect(variables['cursor'], 'people-cursor');
        expect(
          variables['count'],
          5,
          reason: 'People search must send the numeric count and caller cursor from the current contract',
        );
      },
    );
  });

  group('thread cache error handling', () {
    test(
      'Should not replace a cached thread with a GraphQL error body',
      () async {
        await insertAccount('A', isActive: true);
        final temp = await Directory.systemTemp.createTemp(
          'quax-thread-cache-',
        );
        const channel = MethodChannel('plugins.flutter.io/path_provider');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) async => temp.path);
        addTearDown(() async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
          await temp.delete(recursive: true);
        });

        final cacheKey = TimelineCache.keyFor('thread.123');
        final good = jsonEncode({
          'data': {
            'threaded_conversation_with_injections_v2': {'instructions': []},
          },
        });
        await TimelineCache.write(cacheKey, good);
        XRegularAccount.debugFetchOverride =
            (uri, {headers, body, required log, required authHeader}) async =>
                http.Response(
                  jsonEncode({
                    'errors': [
                      {'code': 32, 'message': 'Could not authenticate you'},
                    ],
                    'data': {},
                  }),
                  200,
                );

        await expectLater(
          Twitter.getTweet('123'),
          throwsA(isA<TwitterError>()),
          reason: 'A GraphQL error must surface instead of being disguised as an empty thread',
        );
        expect(
          await TimelineCache.read(cacheKey),
          good,
          reason: 'The last readable thread must survive an error response',
        );
      },
    );
  });

  group('403 transaction-id recovery', () {
    test(
      'Should re-derive the header once and retry the same account',
      () async {
        await insertAccount('A', isActive: true);
        var calls = 0;

        XRegularAccount.debugFetchOverride =
            (uri, {headers, body, required log, required authHeader}) async {
              calls++;
              return calls == 1
                  ? http.Response('', 403)
                  : http.Response('{}', 200);
            };

        final response = await Twitter.debugFetch(
          Uri.parse('https://x.com/i/api/graphql/x/HomeLatestTimeline'),
        );

        expect(
          response.statusCode,
          200,
          reason: '403 means the transaction key is wrong; re-deriving it once should recover',
        );
        expect(
          calls,
          2,
          reason: 'The retry must go to the same account, not be lost by rotating away from it',
        );
      },
    );

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

      expect(
        response.statusCode,
        403,
        reason: 'A second 403 with a fresh header means the request really is forbidden',
      );
      expect(
        calls,
        2,
        reason:
            'Only one retry is allowed, so a broken page cannot retry forever',
      );
    });
  });

  group('guest token budget', () {
    test('Should reject an exhausted token', () {
      expect(
        guestTokenUsable(nowMs: 1000, expiresAt: 2000, remaining: 0),
        isFalse,
        reason:
            'remaining < limit was true for an exhausted token, so every guest request '
            'kept reusing it until the window reset',
      );
    });

    test('Should accept a token with budget left', () {
      expect(
        guestTokenUsable(nowMs: 1000, expiresAt: 2000, remaining: 1),
        isTrue,
      );
    });

    test('Should reject a token past its reset time', () {
      expect(
        guestTokenUsable(nowMs: 3000, expiresAt: 2000, remaining: 1),
        isFalse,
      );
    });

    test('Should accept an unknown window', () {
      expect(
        guestTokenUsable(nowMs: 1000, expiresAt: -1, remaining: -1),
        isTrue,
        reason: 'No endpoint has reported a window yet; the fresh token is still usable',
      );
    });
  });

  group('guest fallback errors', () {
    test(
      'Should keep the default constructor and include an optional status',
      () {
        const missing = NoAccountAvailableException();
        expect(missing.statusCode, isNull);
        expect(missing.toString(), 'No account available');

        final rejected = NoAccountAvailableException(statusCode: 401);
        expect(rejected.statusCode, 401);
        expect(
          rejected.toString(),
          contains('statusCode: 401'),
          reason: 'Live probes must distinguish a rejected guest request from a parse failure',
        );
      },
    );

    test(
      'Should preserve the guest response status when no account is available',
      () async {
        debugGuestFetchOverride = (uri, {headers, required log}) async =>
            http.Response('', 401);

        await expectLater(
          Twitter.debugFetch(
            Uri.parse('https://x.com/i/api/graphql/x/SearchTimeline'),
          ),
          throwsA(
            isA<NoAccountAvailableException>().having(
              (error) => error.statusCode,
              'statusCode',
              401,
            ),
          ),
          reason: 'The guest fallback must report the real HTTP status instead of discarding it',
        );
      },
    );
  });

  group('account identity writes', () {
    test(
      'Should replace the old row when the same handle logs in again',
      () async {
        await saveLoggedInAccount(
          id: 'ct0-1',
          screenName: 'alice',
          userId: 'u1',
          authHeader: '{}',
        );
        await saveLoggedInAccount(
          id: 'ct0-2',
          screenName: 'alice',
          userId: 'u1',
          authHeader: '{}',
        );

        final accounts = await getAccounts();

        expect(
          accounts,
          hasLength(1),
          reason: 'A new ct0 on re-login used to leave the old row behind as a second account',
        );
        expect(
          accounts.single.id,
          'ct0-2',
          reason: 'The fresh session must be the row that survives',
        );
      },
    );

    test('Should keep two different handles as two accounts', () async {
      await saveLoggedInAccount(
        id: 'ct0-1',
        screenName: 'alice',
        authHeader: '{}',
      );
      await saveLoggedInAccount(
        id: 'ct0-2',
        screenName: 'bob',
        authHeader: '{}',
      );

      expect(await getAccounts(), hasLength(2));
    });

    test(
      'Should publish the switch when the last account is deleted',
      () async {
        activeAccount.value = const ActiveAccount(id: 'A');
        accountsRevision.value = 0;

        await promoteFirstAccountIfNoneActive();

        expect(activeAccount.value, isNull);
        expect(
          accountsRevision.value,
          1,
          reason:
              'Feeds and private tabs listen to the revision; without a bump they keep '
              'showing the deleted account\'s content',
        );
      },
    );
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
