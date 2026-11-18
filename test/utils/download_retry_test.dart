import 'package:flutter_test/flutter_test.dart';
import 'package:quax/utils/downloads.dart';

void main() {
  group('resumeOffset()', () {
    test('Should resume from the recorded byte when the partial file matches', () {
      expect(
        resumeOffset(resume: true, recordedBytes: 4096, fileExists: true, fileLength: 4096),
        4096,
        reason: 'A matching partial is the only case where a Range request can continue the file',
      );
    });

    test('Should restart when the partial file is missing or shorter than the ledger', () {
      expect(resumeOffset(resume: true, recordedBytes: 4096, fileExists: false, fileLength: 0), 0,
          reason: 'The OS may have cleared the temp file; appending to nothing would corrupt it');
      expect(resumeOffset(resume: true, recordedBytes: 4096, fileExists: true, fileLength: 4000), 0,
          reason: 'A shorter file means the ledger and the bytes disagree; start over instead of '
              'leaving a hole at the join');
    });

    test('Should not resume a fresh transfer', () {
      expect(resumeOffset(resume: false, recordedBytes: 4096, fileExists: true, fileLength: 4096), 0,
          reason: 'Only a retry or an explicit resume may send a Range header');
    });

    test('Should resume a file that a kill left ahead of the ledger', () {
      expect(
        resumeOffset(resume: true, recordedBytes: 4096, fileExists: true, fileLength: 4800),
        4096,
        reason: 'The ledger is flushed at most every 1.5 s, so a killed transfer always leaves more '
            'bytes on disk than it recorded; treating that as a mismatch restarted every killed '
            'download from zero',
      );
    });

    test('Should not trust a file that is far ahead of the ledger', () {
      expect(
        resumeOffset(resume: true, recordedBytes: 4096, fileExists: true, fileLength: 64 * 1024 * 1024),
        0,
        reason: 'A gap that large means the file and the row are not the pair we think they are',
      );
    });
  });

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

  group('retryDelayFor()', () {
    test('Should grow with every attempt', () {
      final first = retryDelayFor(0);
      final second = retryDelayFor(1);

      expect(first.inMilliseconds, greaterThanOrEqualTo(2000),
          reason: 'the first retry must give the network a moment to recover');
      expect(second, greaterThan(first),
          reason: 'an endpoint that failed twice deserves a longer pause than one that failed once');
    });

    test('Should wait at least as long as the server asked', () {
      final delay = retryDelayFor(0, requested: const Duration(seconds: 45));

      expect(delay.inSeconds, greaterThanOrEqualTo(45),
          reason: 'retrying a 503 before Retry-After expires is what keeps the 503 alive');
    });

    test('Should cap the pause so the queue keeps moving', () {
      final delay = retryDelayFor(9, requested: const Duration(minutes: 30));

      expect(delay, const Duration(minutes: 2),
          reason: 'a server asking for half an hour must not park the only worker for half an hour');
    });
  });

  group('parseRetryAfter()', () {
    test('Should read the seconds form', () {
      expect(parseRetryAfter('30'), const Duration(seconds: 30),
          reason: 'a CDN asks for a pause in whole seconds');
    });

    test('Should ignore a value it cannot read', () {
      expect(parseRetryAfter('Wed, 21 Oct 2026 07:28:00 GMT'), isNull,
          reason: 'the date form falls back to the exponential backoff, not to a crash');
      expect(parseRetryAfter(null), isNull, reason: 'a missing header is not a pause');
    });

    test('Should clamp a hostile value', () {
      expect(parseRetryAfter('0'), const Duration(seconds: 1),
          reason: 'a zero pause would retry in the same tick as the failure');
      expect(parseRetryAfter('100000'), const Duration(seconds: 300),
          reason: 'an absurd header must not become an hours-long sleep');
    });
  });

  group('shouldRestartFromZero()', () {
    test('Should keep the partial on the first server error', () {
      expect(shouldRestartFromZero(0, 'HTTP 503'), isFalse,
          reason: 'one 5xx is often a blip, and throwing away the bytes wastes the resume');
    });

    test('Should drop the partial once a Range-based retry also failed', () {
      expect(shouldRestartFromZero(1, 'HTTP 503'), isTrue,
          reason: 'the second identical Range request proves the offset is what the CDN refuses');
    });

    test('Should keep the partial for a client-side failure', () {
      expect(shouldRestartFromZero(1, 'HTTP 403'), isFalse,
          reason: 'a 403 is not about the Range, and a fresh GET would waste the same bytes');
      expect(shouldRestartFromZero(1, null), isFalse,
          reason: 'no error means no reason to delete anything');
    });
  });
}
