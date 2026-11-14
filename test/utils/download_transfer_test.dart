import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quax/downloads/download_paths.dart';
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

  tearDown(() {
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

    final path = await debugDownloadToTemp(Uri.parse('https://x/clip.mp4'), 'clip.mp4',
        targetDir: temp.path, client: client);

    expect(path, isNotNull, reason: 'A successful transfer has to hand the file to the saver');
    expect(File(path!).readAsStringSync(), 'hello',
        reason: 'The response body must land in the temp file byte for byte');
    expect(queue.itemFor('clip.mp4')?.receivedBytes, 5,
        reason: 'The ledger must end on the bytes that are actually on disk');
  });

  test('Should restart clean when a 206 does not start at the requested offset', () async {
    registerRunning();
    queue.progress('clip.mp4', 5, 11, 0);
    File(await partialPathFor('clip.mp4')).writeAsStringSync('HELLO');

    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) {
        // A proxy that answers 206 for the whole object instead of the range.
        return http.Response('HELLO WORLD', 206,
            headers: {'content-range': 'bytes 0-10/11'});
      }
      return http.Response('HELLO WORLD', 200);
    });

    final path = await debugDownloadToTemp(Uri.parse('https://x/clip.mp4'), 'clip.mp4',
        targetDir: temp.path, resume: true, client: client);

    expect(path, isNotNull);
    expect(File(path!).readAsStringSync(), 'HELLO WORLD',
        reason: 'Appending the whole 206 body after the partial would corrupt the file');
    expect(calls, 2,
        reason: 'A 206 from the wrong offset must be discarded and re-requested from zero');
  });

  test('Should restart clean when the partial no longer matches the remote file', () async {
    registerRunning();
    queue.progress('clip.mp4', 5, 11, 0);
    File(await partialPathFor('clip.mp4')).writeAsStringSync('HELLO');

    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) return http.Response('', 416);
      return http.Response('HELLO WORLD', 200);
    });

    final path = await debugDownloadToTemp(Uri.parse('https://x/clip.mp4'), 'clip.mp4',
        targetDir: temp.path, resume: true, client: client);

    expect(path, isNotNull);
    expect(File(path!).readAsStringSync(), 'HELLO WORLD',
        reason: 'A 416 means the Range is unusable, so the retry has to start from zero');
    expect(calls, 2);
  });

  test('Should resume from the bytes flushed after the last progress sample', () {
    registerRunning();
    queue.progress('clip.mp4', 3, 6, 0);
    // The sink closes after the last sample and flushes two more bytes.
    queue.recordBytes('clip.mp4', 5, 6);
    queue.pause('clip.mp4');
    queue.startRunning('clip.mp4');

    expect(queue.resumeOffsetFor('clip.mp4'), 5,
        reason: 'A resume compares the file length with the ledger; recording only the 250 ms '
            'sample made the partial file look too long and restarted the download from zero');
  });
}
