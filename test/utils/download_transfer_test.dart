import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:quax/downloads/download_paths.dart';
import 'package:quax/constants.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/utils/downloads.dart';

void main() {
  // The free-space probe goes through a MethodChannel; without a binding its
  // FlutterError escapes the `on Exception` guard.
  TestWidgetsFlutterBinding.ensureInitialized();

  final queue = DownloadsModel();
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quax-transfer-');
    debugTempDirectoryOverride = temp;
    DownloadsModel.debugDirectoryOverride = temp;
    queue.resetForTests();
  });

  tearDown(() async {
    await queue.flush();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(quaxMethodChannel, null);
    debugTempDirectoryOverride = null;
    DownloadsModel.debugDirectoryOverride = null;
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {
      // The OS may still hold the temp file briefly.
    }
  });

  void registerRunning() {
    queue.register('clip.mp4', 'https://x/clip.mp4', true);
    queue.startRunning('clip.mp4');
  }

  test('Should write a 200 body and return the temp path', () async {
    registerRunning();
    final client = MockClient((request) async => http.Response('hello', 200));

    final path = await debugDownloadToTemp(
      Uri.parse('https://x/clip.mp4'),
      'clip.mp4',
      targetDir: temp.path,
      client: client,
    );

    expect(
      path,
      isNotNull,
      reason: 'A successful transfer has to hand the file to the saver',
    );
    expect(
      File(path!).readAsStringSync(),
      'hello',
      reason: 'The response body must land in the temp file byte for byte',
    );
    expect(
      queue.itemFor('clip.mp4')?.receivedBytes,
      5,
      reason: 'The ledger must end on the bytes that are actually on disk',
    );
  });

  test(
    'Should restart clean when a 206 does not start at the requested offset',
    () async {
      registerRunning();
      queue.progress('clip.mp4', 5, 11, 0);
      File(await partialPathFor('clip.mp4')).writeAsStringSync('HELLO');

      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls == 1) {
          // A proxy that answers 206 for the whole object instead of the range.
          return http.Response(
            'HELLO WORLD',
            206,
            headers: {'content-range': 'bytes 0-10/11'},
          );
        }
        return http.Response('HELLO WORLD', 200);
      });

      final path = await debugDownloadToTemp(
        Uri.parse('https://x/clip.mp4'),
        'clip.mp4',
        targetDir: temp.path,
        resume: true,
        client: client,
      );

      expect(path, isNotNull);
      expect(
        File(path!).readAsStringSync(),
        'HELLO WORLD',
        reason: 'Appending the whole 206 body after the partial would corrupt the file',
      );
      expect(
        calls,
        2,
        reason: 'A 206 from the wrong offset must be discarded and re-requested from zero',
      );
    },
  );

  test('Should reject a fresh 206 that starts after byte zero', () async {
    registerRunning();
    final id = queue.itemFor('clip.mp4')!.attemptId;
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response(
        ' WORLD',
        206,
        headers: {'content-range': 'bytes 5-10/11'},
      );
    });

    final path = await debugDownloadToTemp(
      Uri.parse('https://x/clip.mp4'),
      'clip.mp4',
      targetDir: temp.path,
      client: client,
    );

    expect(
      path,
      isNull,
      reason: 'A fresh request has no byte-five prefix for the server tail to continue',
    );
    expect(
      calls,
      1,
      reason: 'An invalid fresh range must be rejected before opening the sink',
    );
    expect(queue.itemFor('clip.mp4')?.error, 'invalid_range');
    expect(
      await File(await partialPathFor('clip.mp4', attemptId: id)).exists(),
      isFalse,
      reason:
          'Rejecting before the sink must not create a corrupt partial file',
    );
  });

  test(
    'Should reject a post-restart 206 that does not start at zero',
    () async {
      registerRunning();
      final id = queue.itemFor('clip.mp4')!.attemptId;
      queue.progress('clip.mp4', 5, 11, 0, attemptId: id);
      File(await partialPathFor('clip.mp4', attemptId: id))
          .writeAsStringSync('HELLO');
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            'HELLO WORLD',
            206,
            headers: {'content-range': 'bytes 0-10/11'},
          );
        }
        return http.Response(
          ' WORLD',
          206,
          headers: {'content-range': 'bytes 5-10/11'},
        );
      });

      final path = await debugDownloadToTemp(
        Uri.parse('https://x/clip.mp4'),
        'clip.mp4',
        targetDir: temp.path,
        resume: true,
        client: client,
      );

      expect(
        path,
        isNull,
        reason: 'After restarting at zero, a byte-five range still has no valid prefix',
      );
      expect(calls, 2);
      expect(queue.itemFor('clip.mp4')?.error, 'invalid_range');
    },
  );

  test(
    'Should skip the full target allocation for a same-volume rename',
    () async {
      final partialDir = Directory('${temp.path}/partial')..createSync();
      final targetDir = Directory('${temp.path}/target')..createSync();
      debugTempDirectoryOverride = partialDir;
      registerRunning();
      final id = queue.itemFor('clip.mp4')!.attemptId;
      queue.progress('clip.mp4', 5, 11, 0, attemptId: id);
      File(await partialPathFor('clip.mp4', attemptId: id))
          .writeAsStringSync('HELLO');
      const margin = 64 * 1024 * 1024;
      final spaceChecks = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(quaxMethodChannel, (call) async {
            final args = call.arguments as Map;
            if (call.method == 'isSameStorageVolume') {
              expect(args['path1'], partialDir.path);
              expect(args['path2'], targetDir.path);
              return true;
            }
            expect(call.method, 'getAvailableSpace');
            final path = args['path'] as String;
            spaceChecks.add(path);
            return margin + 6;
          });
      final client = MockClient(
        (request) async => http.Response(
          ' WORLD',
          206,
          headers: {'content-range': 'bytes 5-10/11'},
        ),
      );

      final path = await debugDownloadToTemp(
        Uri.parse('https://x/clip.mp4'),
        'clip.mp4',
        targetDir: targetDir.path,
        resume: true,
        client: client,
      );

      expect(
        path,
        isNotNull,
        reason: 'A rename on the same volume needs only the six remaining bytes plus margin',
      );
      expect(
        spaceChecks,
        [partialDir.path],
        reason:
            'Checking the target again would count the same free bytes twice',
      );
    },
  );

  test(
    'Should skip unknown SAF target preflight and keep the resumable temp',
    () async {
      final partialDir = Directory('${temp.path}/partial')..createSync();
      debugTempDirectoryOverride = partialDir;
      registerRunning();
      final id = queue.itemFor('clip.mp4')!.attemptId;
      queue.progress('clip.mp4', 5, 11, 0, attemptId: id);
      final partial = File(await partialPathFor('clip.mp4', attemptId: id))
        ..writeAsStringSync('HELLO');
      const margin = 64 * 1024 * 1024;
      final spaceChecks = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(quaxMethodChannel, (call) async {
            if (call.method == 'isSameStorageVolume') {
              fail('SAF has no selected destination volume yet');
            }
            expect(call.method, 'getAvailableSpace');
            final path = (call.arguments as Map)['path'] as String;
            spaceChecks.add(path);
            return margin + 6;
          });
      final client = MockClient(
        (request) async => http.Response(
          ' WORLD',
          206,
          headers: {'content-range': 'bytes 5-10/11'},
        ),
      );

      final path = await debugDownloadToTemp(
        Uri.parse('https://x/clip.mp4'),
        'clip.mp4',
        targetDir: partialDir.path,
        resume: true,
        destinationIsSaf: true,
        client: client,
      );

      expect(
        path,
        isNotNull,
        reason: 'The temp directory is not the SAF destination and cannot preflight its space',
      );
      expect(File(path!).readAsStringSync(), 'HELLO WORLD');
      expect(
        spaceChecks,
        [partialDir.path],
        reason:
            'Only the temp volume can be checked before the user selects a URI',
      );
      expect(
        await partial.exists(),
        isTrue,
        reason: 'The complete temp remains available if the later native URI copy fails',
      );
    },
  );

  test(
    'Should check only remaining temp bytes but the full target on resume',
    () async {
      final partialDir = Directory('${temp.path}/partial')..createSync();
      final targetDir = Directory('${temp.path}/target')..createSync();
      debugTempDirectoryOverride = partialDir;
      registerRunning();
      final id = queue.itemFor('clip.mp4')!.attemptId;
      queue.progress('clip.mp4', 5, 11, 0, attemptId: id);
      File(await partialPathFor('clip.mp4', attemptId: id))
          .writeAsStringSync('HELLO');
      const margin = 64 * 1024 * 1024;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(quaxMethodChannel, (call) async {
            if (call.method == 'isSameStorageVolume') return false;
            expect(call.method, 'getAvailableSpace');
            final path = (call.arguments as Map)['path'] as String;
            return p.equals(path, partialDir.path)
                ? margin + 6
                : 1024 * 1024 * 1024;
          });
      final client = MockClient(
        (request) async => http.Response(
          ' WORLD',
          206,
          headers: {'content-range': 'bytes 5-10/11'},
        ),
      );

      final path = await debugDownloadToTemp(
        Uri.parse('https://x/clip.mp4'),
        'clip.mp4',
        targetDir: targetDir.path,
        resume: true,
        client: client,
      );

      expect(
        path,
        isNotNull,
        reason: 'The temp volume already holds five bytes and only needs the six-byte remainder',
      );
    },
  );

  test('Should still require room for the complete target on resume', () async {
    final partialDir = Directory('${temp.path}/partial')..createSync();
    final targetDir = Directory('${temp.path}/target')..createSync();
    debugTempDirectoryOverride = partialDir;
    registerRunning();
    final id = queue.itemFor('clip.mp4')!.attemptId;
    queue.progress('clip.mp4', 5, 11, 0, attemptId: id);
    File(await partialPathFor('clip.mp4', attemptId: id))
        .writeAsStringSync('HELLO');
    const margin = 64 * 1024 * 1024;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(quaxMethodChannel, (call) async {
          if (call.method == 'isSameStorageVolume') {
            throw PlatformException(code: 'UNAVAILABLE');
          }
          final path = (call.arguments as Map)['path'] as String;
          return p.equals(path, partialDir.path) ? margin + 6 : margin + 10;
        });
    final client = MockClient(
      (request) async => http.Response(
        ' WORLD',
        206,
        headers: {'content-range': 'bytes 5-10/11'},
      ),
    );

    final path = await debugDownloadToTemp(
      Uri.parse('https://x/clip.mp4'),
      'clip.mp4',
      targetDir: targetDir.path,
      resume: true,
      client: client,
    );

    expect(
      path,
      isNull,
      reason: 'A cross-volume promotion may need all eleven bytes on the destination',
    );
    expect(queue.itemFor('clip.mp4')?.error, 'no_space');
  });

  test('Should reject a short but syntactically valid 206 instead of completing it', () async {
    registerRunning();
    queue.progress(
      'clip.mp4',
      5,
      11,
      0,
      attemptId: queue.itemFor('clip.mp4')!.attemptId,
    );
    final partial = File(
      await partialPathFor(
        'clip.mp4',
        attemptId: queue.itemFor('clip.mp4')!.attemptId,
      ),
    );
    partial.writeAsStringSync('HELLO');
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response(
        'X',
        206,
        headers: {'content-range': 'bytes 5-5/11'},
      );
    });

    final path = await debugDownloadToTemp(
      Uri.parse('https://x/clip.mp4'),
      'clip.mp4',
      targetDir: temp.path,
      resume: true,
      client: client,
    );

    expect(
      path,
      isNull,
      reason: 'One byte cannot complete an eleven-byte object after a five-byte partial',
    );
    expect(
      calls,
      1,
      reason: 'A malformed continuation is rejected, not silently retried as success',
    );
    expect(
      queue.itemFor('clip.mp4')?.error,
      'invalid_range',
      reason: 'The queue must explain why the response was not accepted',
    );
    expect(
      partial.readAsStringSync(),
      'HELLO',
      reason: 'Rejecting the response must preserve the resumable prefix',
    );
  });

  test(
    'Should restart clean when the partial no longer matches the remote file',
    () async {
      registerRunning();
      queue.progress('clip.mp4', 5, 11, 0);
      File(await partialPathFor('clip.mp4')).writeAsStringSync('HELLO');

      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls == 1) return http.Response('', 416);
        return http.Response('HELLO WORLD', 200);
      });

      final path = await debugDownloadToTemp(
        Uri.parse('https://x/clip.mp4'),
        'clip.mp4',
        targetDir: temp.path,
        resume: true,
        client: client,
      );

      expect(path, isNotNull);
      expect(
        File(path!).readAsStringSync(),
        'HELLO WORLD',
        reason: 'A 416 means the Range is unusable, so the retry has to start from zero',
      );
      expect(calls, 2);
    },
  );

  test(
    'Should resume from the bytes flushed after the last progress sample',
    () {
      registerRunning();
      queue.progress('clip.mp4', 3, 6, 0);
      // The sink closes after the last sample and flushes two more bytes.
      queue.recordBytes('clip.mp4', 5, 6);
      queue.pause('clip.mp4');
      queue.requeue('clip.mp4');
      queue.startRunning('clip.mp4');

      expect(
        queue.resumeOffsetFor('clip.mp4'),
        5,
        reason:
            'A resume compares the file length with the ledger; recording only the 250 ms '
            'sample made the partial file look too long and restarted the download from zero',
      );
    },
  );

  test(
    'Should truncate the bytes a killed transfer wrote after the last sample',
    () async {
      registerRunning();
      queue.progress('clip.mp4', 5, 11, 0);
      // The process died mid-write: five extra bytes are on disk but not in the
      // ledger.
      File(await partialPathFor('clip.mp4')).writeAsStringSync('HELLOEXTRA');

      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response(
          ' WORLD',
          206,
          headers: {'content-range': 'bytes 5-10/11'},
        );
      });

      final path = await debugDownloadToTemp(
        Uri.parse('https://x/clip.mp4'),
        'clip.mp4',
        targetDir: temp.path,
        resume: true,
        client: client,
      );

      expect(
        seen.headers['range'],
        'bytes=5-',
        reason: 'the recorded byte is the only offset the ledger can vouch for',
      );
      expect(
        File(path!).readAsStringSync(),
        'HELLO WORLD',
        reason: 'the unrecorded tail must be dropped, or the file gains five bytes of garbage',
      );
    },
  );

  test(
    'Should replace the partial when the server ignores the Range header',
    () async {
      registerRunning();
      queue.progress('clip.mp4', 5, 11, 0);
      File(await partialPathFor('clip.mp4')).writeAsStringSync('HELLO');

      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        // A proxy or an edge that does not do partial content.
        return http.Response('HELLO WORLD', 200);
      });

      final path = await debugDownloadToTemp(
        Uri.parse('https://x/clip.mp4'),
        'clip.mp4',
        targetDir: temp.path,
        resume: true,
        client: client,
      );

      expect(
        seen.headers['range'],
        'bytes=5-',
        reason: 'the request still asks for the remainder, so a server that supports Range resumes',
      );
      expect(
        File(path!).readAsStringSync(),
        'HELLO WORLD',
        reason:
            'a 200 carries the whole object; appending it after the partial would leave eleven '
            'bytes of garbage at the join and a file that never plays',
      );
    },
  );

  test(
    'Should send If-Range so a changed object restarts instead of splicing',
    () async {
      registerRunning();
      queue.progress('clip.mp4', 5, 11, 0);
      queue.setValidator('clip.mp4', etag: '"abc123"');
      File(await partialPathFor('clip.mp4')).writeAsStringSync('HELLO');

      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response(
          ' WORLD',
          206,
          headers: {'content-range': 'bytes 5-10/11'},
        );
      });

      await debugDownloadToTemp(
        Uri.parse('https://x/clip.mp4'),
        'clip.mp4',
        targetDir: temp.path,
        resume: true,
        client: client,
      );

      expect(
        seen.headers['if-range'],
        '"abc123"',
        reason:
            'without a validator a re-encoded video at the same URL is appended to the old '
            'bytes and the result still looks finished',
      );
    },
  );
}
