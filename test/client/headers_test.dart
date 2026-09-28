import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/headers.dart';
import 'package:quax/client/x_client_transaction_id/client_transaction.dart';

void main() {
  final uri = Uri.parse('https://x.com/i/api/graphql/abc/TweetDetail');

  setUp(() {
    TwitterHeaders.resetForTests();
  });

  tearDown(() {
    ClientTransaction.initializeOverride = null;
  });

  test(
    'Should fail open when the transaction page cannot be scraped',
    () async {
      var attempts = 0;
      ClientTransaction.initializeOverride = () async {
        attempts++;
        // X changed its page shape: the scrape throws instead of returning.
        throw Exception("Couldn't find ondemand file index");
      };

      final headers = await TwitterHeaders.getXClientTransactionIdHeader(uri);

      expect(
        headers,
        isNull,
        reason:
            'The feed must keep working without the anti-bot header instead '
            'of showing "Unable to load the posts" to the user',
      );
      expect(attempts, 1, reason: 'The failed initialization ran exactly once');
    },
  );

  test(
    'Should not re-attempt a failing initialization inside the backoff window',
    () async {
      var attempts = 0;
      ClientTransaction.initializeOverride = () async {
        attempts++;
        throw Exception("Couldn't find ondemand file index");
      };

      await TwitterHeaders.getXClientTransactionIdHeader(uri);
      await TwitterHeaders.getXClientTransactionIdHeader(uri);

      expect(
        attempts,
        1,
        reason:
            'A failing init fetches x.com twice; repeating that on every '
            'API call would hammer x.com while the page shape is broken',
      );
      expect(
        TwitterHeaders.failureRetryAt,
        isNotNull,
        reason: 'The backoff window is what suppresses the immediate retry',
      );
    },
  );

  test(
    'Should retry the initialization once the backoff window has passed',
    () async {
      var attempts = 0;
      ClientTransaction.initializeOverride = () async {
        attempts++;
        throw Exception("Couldn't find ondemand file index");
      };

      await TwitterHeaders.getXClientTransactionIdHeader(uri);
      // Simulate the cooldown having passed.
      TwitterHeaders.failureRetryAt = DateTime.now().subtract(
        const Duration(seconds: 1),
      );

      final headers = await TwitterHeaders.getXClientTransactionIdHeader(uri);

      expect(
        attempts,
        2,
        reason:
            'The self-heal path must keep trying: X can restore the page '
            'shape (or the network) at any time',
      );
      expect(
        headers,
        isNull,
        reason: 'A retry that fails again still fails open',
      );
    },
  );

  test(
    'Should keep the base headers when the transaction id is unavailable',
    () async {
      ClientTransaction.initializeOverride = () async {
        throw Exception("Couldn't find ondemand file index");
      };

      final headers = await TwitterHeaders.getHeaders(uri, null);

      expect(
        headers.containsKey('authorization'),
        isTrue,
        reason: 'The request still goes out, so it must carry the auth headers',
      );
      expect(
        headers.containsKey('x-client-transaction-id'),
        isFalse,
        reason: 'No transaction id was produced, so none must be invented',
      );
    },
  );
}
