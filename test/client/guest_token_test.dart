import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:quax/client/client_unauthenticated.dart';
import 'package:quax/client/http_client.dart';

void main() {
  final log = Logger('guest token test');

  setUp(() {
    resetGuestTokenForTests();
  });

  tearDown(() {
    // Restore the real client for the remaining tests in the suite.
    quaxHttpClient = http.Client();
  });

  /// A fake X: token activations and page fetches are counted, and each page
  /// answers with the rate-limit headers the caller asks for.
  ({http.Client client, List<int> activations, List<int> fetches}) fakeX({
    required String remaining,
    required String limit,
    required String reset,
  }) {
    final activations = <int>[];
    final fetches = <int>[];

    final client = MockClient((request) async {
      if (request.url.host == 'api.x.com' &&
          request.url.path.endsWith('guest/activate.json')) {
        activations.add(1);
        return http.Response(
          '{"guest_token": "token${activations.length}"}',
          200,
        );
      }

      fetches.add(1);
      return http.Response(
        '{}',
        200,
        headers: {
          'x-rate-limit-remaining': remaining,
          'x-rate-limit-limit': limit,
          'x-rate-limit-reset': reset,
        },
      );
    });

    return (client: client, activations: activations, fetches: fetches);
  }

  String epochSeconds({required int secondsFromNow}) =>
      (DateTime.now().millisecondsSinceEpoch ~/ 1000 + secondsFromNow)
          .toString();

  test(
    'Should reuse one guest token across requests while its window is open',
    () async {
      final fake = fakeX(
        remaining: '59',
        limit: '60',
        reset: epochSeconds(secondsFromNow: 900),
      );
      quaxHttpClient = fake.client;

      await fetchUnauthenticated(
        Uri.parse('https://x.com/i/api/graphql/test'),
        log: log,
      );
      await fetchUnauthenticated(
        Uri.parse('https://x.com/i/api/graphql/test'),
        log: log,
      );

      expect(
        fake.activations.length,
        1,
        reason:
            'A token with a valid window must be reused; re-activating on every call burns '
            'the very rate limit the token exists to spend',
      );
      expect(
        fake.fetches.length,
        2,
        reason: 'Both page requests must still go out',
      );
    },
  );

  test('Should activate a fresh token after its usages ran out', () async {
    final fake = fakeX(
      remaining: '60',
      limit: '60',
      reset: epochSeconds(secondsFromNow: 900),
    );
    quaxHttpClient = fake.client;

    await fetchUnauthenticated(
      Uri.parse('https://x.com/i/api/graphql/test'),
      log: log,
    );
    await fetchUnauthenticated(
      Uri.parse('https://x.com/i/api/graphql/test'),
      log: log,
    );

    expect(
      fake.activations.length,
      2,
      reason:
          'When remaining hits the limit the window is spent, so the next request must '
          'activate a new token instead of reusing a dead one',
    );
  });

  test('Should activate a fresh token after its window expired', () async {
    final fake = fakeX(
      remaining: '59',
      limit: '60',
      reset: epochSeconds(secondsFromNow: -60),
    );
    quaxHttpClient = fake.client;

    await fetchUnauthenticated(
      Uri.parse('https://x.com/i/api/graphql/test'),
      log: log,
    );
    await fetchUnauthenticated(
      Uri.parse('https://x.com/i/api/graphql/test'),
      log: log,
    );

    expect(
      fake.activations.length,
      2,
      reason: 'A token whose reset time lies in the past is expired and must not be reused',
    );
  });

  test(
    'Should survive a malformed rate-limit header without losing the token',
    () async {
      final fake = fakeX(
        remaining: 'not-a-number',
        limit: '60',
        reset: epochSeconds(secondsFromNow: 900),
      );
      quaxHttpClient = fake.client;

      await fetchUnauthenticated(
        Uri.parse('https://x.com/i/api/graphql/test'),
        log: log,
      );
      await fetchUnauthenticated(
        Uri.parse('https://x.com/i/api/graphql/test'),
        log: log,
      );

      expect(
        fake.activations.length,
        1,
        reason:
            'A header that does not parse must be ignored, not crash the fetch and not '
            'invalidate a token that is still fine',
      );
    },
  );
}
