import 'package:flutter_test/flutter_test.dart';
import 'package:quax/downloads/downloads_model.dart';

void main() {
  final queue = DownloadsModel();

  setUp(() => queue.resetForTests());

  group('register()', () {
    test('Should add a waiting entry instead of running it right away', () {
      queue.register('clip.mp4', 'https://x/clip.mp4', true);

      expect(queue.itemFor('clip.mp4')?.status, DownloadStatus.queued,
          reason: 'Downloads run one at a time, so a new file must wait its turn');
      expect(queue.isActive('clip.mp4'), isTrue,
          reason: 'A waiting entry counts as active: re-requesting it must not start a second transfer');
    });

    test('Should replace an existing entry and reset its progress', () {
      queue.register('clip.mp4', 'https://x/old.mp4', true);
      queue.startRunning('clip.mp4');
      queue.progress('clip.mp4', 500, 1000, 1);
      queue.register('clip.mp4', 'https://x/new.mp4', true);

      final item = queue.itemFor('clip.mp4');
      expect(item?.url, 'https://x/new.mp4', reason: 'A re-download should point at the new URL');
      expect(item?.receivedBytes, 0, reason: 'The stale progress of the previous transfer must not leak in');
      expect(item?.status, DownloadStatus.queued, reason: 'The fresh request waits for the queue like any other');
    });
  });

  group('startRunning()', () {
    test('Should flip a waiting entry to running', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');

      expect(queue.itemFor('a.mp4')?.status, DownloadStatus.running,
          reason: 'The head of the queue is the single running transfer');
    });
  });

  group('pause()', () {
    test('Should park the entry and keep the received bytes', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');
      queue.progress('a.mp4', 512, 1024, 1);

      queue.pause('a.mp4');

      final item = queue.itemFor('a.mp4');
      expect(item?.status, DownloadStatus.paused, reason: 'A pause must be a resting state, not a failure');
      expect(item?.receivedBytes, 512, reason: 'The partial bytes stay so the resume can send a Range request');
      expect(queue.isPaused('a.mp4'), isTrue, reason: 'The transfer loop needs to know an abort was a pause');
      expect(queue.isActive('a.mp4'), isTrue, reason: 'A paused entry still owns the file: no duplicate downloads');
    });

    test('Should ignore progress events that arrive after the pause', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');
      queue.progress('a.mp4', 512, 1024, 1);
      queue.pause('a.mp4');
      queue.progress('a.mp4', 900, 1024, 1);

      expect(queue.itemFor('a.mp4')?.receivedBytes, 512,
          reason: 'Late chunks from the aborted socket must not overwrite the parked offset');
    });
  });

  group('requeue()', () {
    test('Should send a paused entry back to the waiting line', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');
      queue.progress('a.mp4', 512, 1024, 1);
      queue.pause('a.mp4');

      queue.requeue('a.mp4');

      expect(queue.itemFor('a.mp4')?.status, DownloadStatus.queued,
          reason: 'Resuming goes through the one-at-a-time queue again');
      expect(queue.isPaused('a.mp4'), isFalse, reason: 'The paused flag must not survive a resume');
    });

    test('Should expose the offset only while running', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');
      queue.progress('a.mp4', 512, 1024, 1);
      queue.fail('a.mp4', error: 'timeout');
      queue.requeue('a.mp4');

      expect(queue.resumeOffsetFor('a.mp4'), 0,
          reason: 'A waiting entry has no running transfer to resume');
      queue.startRunning('a.mp4');
      expect(queue.resumeOffsetFor('a.mp4'), 512,
          reason: 'Once running, the retry reads the partial bytes to build the Range header');
    });
  });

  group('fail()', () {
    test('Should keep the partial bytes for a later retry', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');
      queue.progress('a.mp4', 512, 1024, 1);

      queue.fail('a.mp4', error: 'timeout');

      final item = queue.itemFor('a.mp4');
      expect(item?.status, DownloadStatus.error, reason: 'A failed transfer is retryable, not disposable');
      expect(item?.error, 'timeout', reason: 'The queue screen shows the failure reason');
      expect(item?.receivedBytes, 512, reason: 'Dropping the partial would force the retry to start over');
    });
  });

  group('cancel()', () {
    test('Should drop the entry and flag the abort', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');

      queue.cancel('a.mp4');

      expect(queue.contains('a.mp4'), isFalse, reason: 'A cancelled download leaves the queue entirely');
      expect(queue.isCancelled('a.mp4'), isTrue,
          reason: 'The streaming loop checks this flag to delete the partial file it was writing');
    });

    test('Should clear the cancellation when the file is queued again', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.cancel('a.mp4');
      queue.register('a.mp4', 'https://x/a.mp4', true);

      expect(queue.isCancelled('a.mp4'), isFalse,
          reason: 'A new download of the same file must not inherit the previous cancellation');
    });
  });

  group('markDone() and clearFinished()', () {
    test('Should mark the entry done and keep history entries separate', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');
      queue.markDone('a.mp4');
      queue.register('b.mp4', 'https://x/b.mp4', true);

      expect(queue.itemFor('a.mp4')?.status, DownloadStatus.done,
          reason: 'Finished entries stay listed as history');
      expect(queue.isActive('a.mp4'), isFalse, reason: 'A finished file is free to be downloaded again');

      queue.clearFinished();

      expect(queue.contains('a.mp4'), isFalse, reason: 'Clearing history removes the finished rows');
      expect(queue.contains('b.mp4'), isTrue, reason: 'Waiting entries must survive a history cleanup');
    });
  });
}
