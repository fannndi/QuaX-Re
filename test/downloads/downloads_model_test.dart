import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quax/downloads/downloads_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final queue = DownloadsModel();
  late Directory support;

  setUp(() {
    support = Directory.systemTemp.createTempSync('quax-model-');
    DownloadsModel.debugDirectoryOverride = support;
    queue.resetForTests();
  });

  tearDown(() async {
    await queue.flush();
    queue.resetForTests();
    DownloadsModel.debugDirectoryOverride = null;
    support.deleteSync(recursive: true);
  });

  group('register()', () {
    test('Should add a waiting entry instead of running it right away', () {
      queue.register('clip.mp4', 'https://x/clip.mp4', true);

      expect(
        queue.itemFor('clip.mp4')?.status,
        DownloadStatus.queued,
        reason: 'Downloads run one at a time, so a new file must wait its turn',
      );
      expect(
        queue.isActive('clip.mp4'),
        isTrue,
        reason: 'A waiting entry counts as active: re-requesting it must not start a second transfer',
      );
    });

    test('Should replace an existing entry and reset its progress', () {
      queue.register('clip.mp4', 'https://x/old.mp4', true);
      queue.startRunning('clip.mp4');
      queue.progress('clip.mp4', 500, 1000, 1);
      queue.register('clip.mp4', 'https://x/new.mp4', true);

      final item = queue.itemFor('clip.mp4');
      expect(
        item?.url,
        'https://x/new.mp4',
        reason: 'A re-download should point at the new URL',
      );
      expect(
        item?.receivedBytes,
        0,
        reason: 'The stale progress of the previous transfer must not leak in',
      );
      expect(
        item?.status,
        DownloadStatus.queued,
        reason: 'The fresh request waits for the queue like any other',
      );
    });
  });

  group('startRunning()', () {
    test('Should flip a waiting entry to running', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');

      expect(
        queue.itemFor('a.mp4')?.status,
        DownloadStatus.running,
        reason: 'The head of the queue is the single running transfer',
      );
    });
  });

  group('pause()', () {
    test('Should park the entry and keep the received bytes', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');
      queue.progress('a.mp4', 512, 1024, 1);

      queue.pause('a.mp4');

      final item = queue.itemFor('a.mp4');
      expect(
        item?.status,
        DownloadStatus.paused,
        reason: 'A pause must be a resting state, not a failure',
      );
      expect(
        item?.receivedBytes,
        512,
        reason: 'The partial bytes stay so the resume can send a Range request',
      );
      expect(
        queue.isPaused('a.mp4'),
        isTrue,
        reason: 'The transfer loop needs to know an abort was a pause',
      );
      expect(
        queue.isActive('a.mp4'),
        isTrue,
        reason: 'A paused entry still owns the file: no duplicate downloads',
      );
    });

    test('Should ignore progress events that arrive after the pause', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');
      queue.progress('a.mp4', 512, 1024, 1);
      queue.pause('a.mp4');
      queue.progress('a.mp4', 900, 1024, 1);

      expect(
        queue.itemFor('a.mp4')?.receivedBytes,
        512,
        reason: 'Late chunks from the aborted socket must not overwrite the parked offset',
      );
    });
  });

  group('requeue()', () {
    test('Should send a paused entry back to the waiting line', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');
      queue.progress('a.mp4', 512, 1024, 1);
      queue.pause('a.mp4');

      queue.requeue('a.mp4');

      expect(
        queue.itemFor('a.mp4')?.status,
        DownloadStatus.queued,
        reason: 'Resuming goes through the one-at-a-time queue again',
      );
      expect(
        queue.isPaused('a.mp4'),
        isFalse,
        reason: 'The paused flag must not survive a resume',
      );
    });

    test('Should expose the offset only while running', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');
      queue.progress('a.mp4', 512, 1024, 1);
      queue.fail('a.mp4', error: 'timeout');
      queue.requeue('a.mp4');

      expect(
        queue.resumeOffsetFor('a.mp4'),
        0,
        reason: 'A waiting entry has no running transfer to resume',
      );
      queue.startRunning('a.mp4');
      expect(
        queue.resumeOffsetFor('a.mp4'),
        512,
        reason: 'Once running, the retry reads the partial bytes to build the Range header',
      );
    });
  });

  group('fail()', () {
    test('Should keep the partial bytes for a later retry', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');
      queue.progress('a.mp4', 512, 1024, 1);

      queue.fail('a.mp4', error: 'timeout');

      final item = queue.itemFor('a.mp4');
      expect(
        item?.status,
        DownloadStatus.error,
        reason: 'A failed transfer is retryable, not disposable',
      );
      expect(
        item?.error,
        'timeout',
        reason: 'The queue screen shows the failure reason',
      );
      expect(
        item?.receivedBytes,
        512,
        reason: 'Dropping the partial would force the retry to start over',
      );
    });
  });

  group('cancel()', () {
    test('Should drop the entry and flag the abort', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');

      queue.cancel('a.mp4');

      expect(
        queue.contains('a.mp4'),
        isFalse,
        reason: 'A cancelled download leaves the queue entirely',
      );
      expect(
        queue.isCancelled('a.mp4'),
        isTrue,
        reason: 'The streaming loop checks this flag to delete the partial file it was writing',
      );
    });

    test('Should reject stale attempt events after the same name is registered again', () {
      queue.register('clip.mp4', 'https://x/old.mp4', true);
      final old = queue.itemFor('clip.mp4')!;
      var oldAborted = false;
      queue.attachCancel(
        'clip.mp4',
        () => oldAborted = true,
        attemptId: old.attemptId,
      );
      queue.cancel('clip.mp4');
      expect(
        oldAborted,
        isTrue,
        reason: 'Cancelling the live attempt must still close its socket',
      );

      queue.register('clip.mp4', 'https://x/new.mp4', true);
      final replacement = queue.itemFor('clip.mp4')!;
      var replacementAborted = false;
      queue.attachCancel(
        'clip.mp4',
        () => replacementAborted = true,
        attemptId: replacement.attemptId,
      );

      queue.cancel('clip.mp4', attemptId: old.attemptId);
      queue.progress('clip.mp4', 900, 1000, 1, attemptId: old.attemptId);
      queue.markDone(
        'clip.mp4',
        attemptId: old.attemptId,
        savedPath: '/old.mp4',
      );

      expect(
        replacement.attemptId,
        isNot(old.attemptId),
        reason: 'A fresh request needs a new identity even when the file name is unchanged',
      );
      expect(
        queue.contains('clip.mp4'),
        isTrue,
        reason: 'A late cancel from the old worker must not remove the replacement row',
      );
      expect(
        replacementAborted,
        isFalse,
        reason:
            'The old attempt must not be able to abort the replacement socket',
      );
      expect(
        queue.itemFor('clip.mp4')?.receivedBytes,
        0,
        reason: 'Late progress from the old attempt must not advance the replacement',
      );
      expect(
        queue.itemFor('clip.mp4')?.status,
        DownloadStatus.queued,
        reason: 'Late completion from the old attempt must not finish the replacement',
      );
    });

    test('Should clear the cancellation when the file is queued again', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.cancel('a.mp4');
      queue.register('a.mp4', 'https://x/a.mp4', true);

      expect(
        queue.isCancelled('a.mp4'),
        isFalse,
        reason: 'A new download of the same file must not inherit the previous cancellation',
      );
    });
  });

  group('pause()', () {
    test('Should mark the entry paused even before its abort hook exists', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');

      // The hook is only attached once _downloadToTemp has done its first
      // awaits, so a pause in that window used to find nothing to call and the
      // socket kept running while the entry read "paused".
      queue.pause('a.mp4');

      expect(
        queue.isPaused('a.mp4'),
        isTrue,
        reason:
            'The paused flag is what the transfer loop re-checks per chunk, so it has to be '
            'set even when the abort hook is not attached yet',
      );
      expect(
        queue.itemFor('a.mp4')?.status,
        DownloadStatus.paused,
        reason: 'The entry is parked with its partial bytes for a Range resume',
      );
    });

    test('Should keep the received bytes so a resume continues from them', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');
      queue.progress('a.mp4', 700, 4096, 1);

      queue.pause('a.mp4');

      expect(
        queue.itemFor('a.mp4')?.receivedBytes,
        700,
        reason: 'Pausing must not reset progress: the resume sends a Range request from here',
      );
      expect(
        queue.itemFor('a.mp4')?.speedMbPerSec,
        0,
        reason: 'A paused entry shows no speed',
      );
    });

    test('Should ignore a pause for an entry that is not in the queue', () {
      expect(
        () => queue.pause('missing.mp4'),
        returnsNormally,
        reason: 'The notification action can arrive after the entry was already removed',
      );
    });
  });

  group('pauseAll()', () {
    test('Should wait until the active worker is quiescent', () async {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');
      final entered = Completer<void>();
      final release = Completer<void>();
      final worker = queue.runWorker(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;

      var paused = false;
      final pausing = queue.pauseAll().then((_) => paused = true);
      await Future<void>.delayed(Duration.zero);
      expect(
        paused,
        isFalse,
        reason: 'A storage move must not start while the worker can still promote a file',
      );

      release.complete();
      await worker;
      await pausing;
      expect(
        paused,
        isTrue,
        reason:
            'pauseAll resolves only after the worker has stopped touching disk',
      );
    });

    test('Should park waiting and running entries together', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.register('b.mp4', 'https://x/b.mp4', true);
      queue.startRunning('b.mp4');
      queue.progress('b.mp4', 256, 1024, 1);

      queue.pauseAll();

      expect(
        queue.itemFor('a.mp4')?.status,
        DownloadStatus.paused,
        reason: 'Stop-all must hold the queue, not drop it: resume-all brings it back',
      );
      expect(
        queue.itemFor('b.mp4')?.status,
        DownloadStatus.paused,
        reason: 'The running transfer is paused in place',
      );
      expect(
        queue.itemFor('b.mp4')?.receivedBytes,
        256,
        reason: 'Force-closing the app keeps partial bytes; stop-all must too',
      );
    });

    test('Should leave finished and failed entries alone', () {
      queue.register('done.mp4', 'https://x/done.mp4', true);
      queue.startRunning('done.mp4');
      queue.markDone('done.mp4');
      queue.register('bad.mp4', 'https://x/bad.mp4', true);
      queue.startRunning('bad.mp4');
      queue.fail('bad.mp4', error: 'timeout');

      queue.pauseAll();

      expect(
        queue.itemFor('done.mp4')?.status,
        DownloadStatus.done,
        reason: 'History is not an active transfer',
      );
      expect(
        queue.itemFor('bad.mp4')?.status,
        DownloadStatus.error,
        reason: 'A real failure keeps its error for the retry path',
      );
    });
  });

  group('markDone() and clearFinished()', () {
    test('Should mark the entry done and keep history entries separate', () {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.startRunning('a.mp4');
      queue.markDone('a.mp4');
      queue.register('b.mp4', 'https://x/b.mp4', true);

      expect(
        queue.itemFor('a.mp4')?.status,
        DownloadStatus.done,
        reason: 'Finished entries stay listed as history',
      );
      expect(
        queue.isActive('a.mp4'),
        isFalse,
        reason: 'A finished file is free to be downloaded again',
      );

      queue.clearFinished();

      expect(
        queue.contains('a.mp4'),
        isFalse,
        reason: 'Clearing history removes the finished rows',
      );
      expect(
        queue.contains('b.mp4'),
        isTrue,
        reason: 'Waiting entries must survive a history cleanup',
      );
    });

    test('Should keep the path the file actually landed on', () {
      queue.register('clip.mp4', 'https://x/clip.mp4', true);
      queue.startRunning('clip.mp4');

      queue.markDone('clip.mp4', savedPath: '/library/clip-123.mp4');

      final item = queue.itemFor('clip.mp4')!;
      expect(
        item.savedPath,
        '/library/clip-123.mp4',
        reason:
            'A duplicate name is saved with a timestamp suffix; the done row has to open '
            'that file, not the older one that happened to keep the original name',
      );
      expect(
        DownloadQueueItem.fromJson(item.toJson()).savedPath,
        item.savedPath,
        reason: 'The path must survive the queue ledger across a restart',
      );
    });

    test('Should persist a SAF content URI separately from a filesystem path', () {
      queue.register('clip.mp4', 'https://x/clip.mp4', true);
      queue.startRunning('clip.mp4');
      const uri =
          'content://com.android.externalstorage.documents/tree/primary%3AQuaXLibrary/document/primary%3AQuaXLibrary%2Fclip.mp4';

      queue.markDone('clip.mp4', savedUri: uri);

      final restored = DownloadQueueItem.fromJson(
        queue.itemFor('clip.mp4')!.toJson(),
      );
      expect(
        restored.savedUri,
        uri,
        reason: 'A system save dialog returns a content URI that must survive restarts',
      );
      expect(
        restored.savedPath,
        isNull,
        reason: 'A content URI must never be stored or treated as a filesystem path',
      );
    });

    test('Should migrate old content paths and reject bare document paths', () {
      const uri = 'content://provider/document/primary%3Aclip.mp4';
      final migrated = DownloadQueueItem.fromJson({
        'fileName': 'clip.mp4',
        'url': 'https://x/clip.mp4',
        'savedPath': uri,
      });
      final bareDocument = DownloadQueueItem.fromJson({
        'fileName': 'clip.mp4',
        'url': 'https://x/clip.mp4',
        'savedPath': '/document/primary%3Aclip.mp4',
      });

      expect(migrated.savedPath, isNull);
      expect(
        migrated.savedUri,
        uri,
        reason: 'Older rows that stored a full content URI in savedPath remain reopenable',
      );
      expect(bareDocument.savedPath, isNull);
      expect(
        bareDocument.savedUri,
        isNull,
        reason: 'A file-dialog Uri.path is not a usable filesystem path',
      );
    });

    test('Should point finished rows at the new root after the library moves', () async {
      final oldRoot = Directory.systemTemp.createTempSync('quax-old-').path;
      final newRoot = Directory.systemTemp.createTempSync('quax-new-').path;
      addTearDown(() {
        Directory(oldRoot).deleteSync(recursive: true);
        Directory(newRoot).deleteSync(recursive: true);
      });
      final oldFile = File(p.join(oldRoot, 'clip.mp4'))..writeAsStringSync('x');
      queue.register('clip.mp4', 'https://x/clip.mp4', true);
      await queue.startRunning('clip.mp4');
      queue.markDone('clip.mp4', savedPath: oldFile.path);

      // The move copies the file before the ledger is updated.
      File(p.join(newRoot, 'clip.mp4')).writeAsStringSync('x');
      await queue.relocateSavedPaths(oldRoot, newRoot);

      expect(
        queue.itemFor('clip.mp4')?.savedPath,
        p.join(newRoot, 'clip.mp4'),
        reason:
            'The done card opens savedPath directly; after a library move it pointed at a '
            'file that no longer existed and every finished row looked broken',
      );
    });

    test(
      'Should leave a row on the old root when its file did not move',
      () async {
        final oldRoot = Directory.systemTemp.createTempSync('quax-old-').path;
        final newRoot = Directory.systemTemp.createTempSync('quax-new-').path;
        addTearDown(() {
          Directory(oldRoot).deleteSync(recursive: true);
          Directory(newRoot).deleteSync(recursive: true);
        });
        final oldFile = File(p.join(oldRoot, 'clip.mp4'))
          ..writeAsStringSync('x');
        queue.register('clip.mp4', 'https://x/clip.mp4', true);
        await queue.startRunning('clip.mp4');
        queue.markDone('clip.mp4', savedPath: oldFile.path);

        await queue.relocateSavedPaths(oldRoot, newRoot);

        expect(
          queue.itemFor('clip.mp4')?.savedPath,
          oldFile.path,
          reason:
              'A file that failed to move is still in the old root; pointing the ledger at the '
              'new one made the done card open nothing',
        );
      },
    );
  });

  // Both indices come from ReorderableListView's onReorderItem, which hands the
  // target over already counted from after the source row was lifted out — so
  // no "shift down when moving later" adjustment belongs inside moveItem.
  group('moveItem()', () {
    List<String> order() => queue.state.map((e) => e.fileName).toList();

    void fill() {
      queue.register('a.mp4', 'https://x/a.mp4', true);
      queue.register('b.mp4', 'https://x/b.mp4', true);
      queue.register('c.mp4', 'https://x/c.mp4', true);
    }

    test('Should carry a row down past the ones it clears', () {
      fill();

      queue.moveItem(0, 2);

      expect(
        order(),
        ['b.mp4', 'c.mp4', 'a.mp4'],
        reason:
            'Adjusting the target a second time would land the row one slot early, so the '
            'drag would visibly drop it in the wrong place',
      );
    });

    test('Should carry a row up to the top', () {
      fill();

      queue.moveItem(2, 0);

      expect(
        order(),
        ['c.mp4', 'a.mp4', 'b.mp4'],
        reason:
            'Dragging upward needs no adjustment at all, which is what would break if the '
            'shift were dropped from the wrong direction',
      );
    });

    test('Should swap a row with the neighbour it is dropped on', () {
      fill();

      queue.moveItem(0, 1);

      expect(order(), [
        'b.mp4',
        'a.mp4',
        'c.mp4',
      ], reason: 'The one-step drag is the one the reader uses most');
    });

    test('Should leave the queue alone when the index is not in it', () {
      fill();

      queue.moveItem(7, 0);

      expect(
        order(),
        ['a.mp4', 'b.mp4', 'c.mp4'],
        reason:
            'A stale index from a list that changed underneath the drag must not corrupt the '
            'transfer order',
      );
    });
  });
}
