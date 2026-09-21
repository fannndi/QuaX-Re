import 'package:flutter_test/flutter_test.dart';
import 'package:quax/utils/downloads.dart';

void main() {
  group('isRetryableDownloadError()', () {
    test('Should retry a server-side error', () {
      expect(isRetryableDownloadError('HTTP 500 Internal Server Error'), isTrue,
          reason: 'A 5xx is usually a temporary server problem, so the connectivity watcher should '
              'bring the download back when the network returns');
    });

    test('Should retry a request timeout', () {
      expect(isRetryableDownloadError('HTTP 408 Request Timeout'), isTrue,
          reason: '408 means the connection was too slow, not that the request was wrong, so it '
              'deserves another try like the other connection errors');
    });

    test('Should not retry the other 4xx errors', () {
      for (final error in ['HTTP 400 Bad Request', 'HTTP 403 Forbidden', 'HTTP 404 Not Found']) {
        expect(isRetryableDownloadError(error), isFalse,
            reason: '"$error" will answer the same way forever, so retrying it would only loop '
                'the failed transfer and burn the retry budget');
      }
    });

    test('Should not retry a full disk', () {
      expect(isRetryableDownloadError('no_space'), isFalse,
          reason: 'Space rarely frees itself between two probes, and a half-ignored full disk is '
              'how the temp file ends up truncated');
    });

    test('Should not retry a stale interrupted marker', () {
      expect(isRetryableDownloadError('interrupted'), isFalse,
          reason: 'The marker means the app was killed mid-transfer; the user has to decide when '
              'to pick the file back up');
    });

    test('Should retry a network-level failure', () {
      expect(isRetryableDownloadError('SocketException: Connection failed'), isTrue,
          reason: 'A dropped connection is exactly what the watcher exists for: the same request '
              'usually succeeds once the network is back');
    });

    test('Should not retry when there is no error to judge', () {
      expect(isRetryableDownloadError(null), isFalse,
          reason: 'Retrying without an error string would relaunch every entry the queue could not '
              'classify');
      expect(isRetryableDownloadError(''), isFalse,
          reason: 'An empty error is as unclassifiable as a missing one');
    });
  });
}
