import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';
import 'package:quax/downloads/download_paths.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/downloads/video_cache.dart';

void main() {
  final model = DownloadsModel();
  late Directory support;
  late Directory temp;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('quax-support-');
    temp = await Directory.systemTemp.createTemp('quax-temp-');
    DownloadsModel.debugDirectoryOverride = support;
    debugTempDirectoryOverride = temp;
    model.resetForTests();
  });

  tearDown(() async {
    await model.saveNow();
    model.resetForTests();
    DownloadsModel.debugDirectoryOverride = null;
    debugTempDirectoryOverride = null;
    VideoCache().resetForTests();
    VideoCache.debugDirectoryOverride = null;
    await support.delete(recursive: true);
    await temp.delete(recursive: true);
  });

  test('Should persist the queue and reload it', () async {
    model.register('clip.mp4', 'https://example.com/clip.mp4', true);
    await model.saveNow();

    final ledger = File('${support.path}/downloads.json');
    expect(await ledger.exists(), isTrue,
        reason: 'A queued transfer must survive a process restart');

    model.resetForTests();
    await model.load();

    expect(model.state, hasLength(1),
        reason: 'Loading a valid ledger used to be the only way to recover a killed queue');
    expect(model.state.single.fileName, 'clip.mp4');
    expect(model.state.single.status, DownloadStatus.paused,
        reason: 'A transfer that was waiting when the app died comes back paused for Resume');
  });

  test('Should recover from a truncated ledger instead of losing the app start', () async {
    await File('${support.path}/downloads.json').writeAsString('{not json');

    model.resetForTests();
    await model.load();

    expect(model.state, isEmpty,
        reason: 'A crash mid-write must degrade to an empty queue, not throw on startup');
  });

  test('Should serialize concurrent saves into one valid ledger', () async {
    model.register('a.mp4', 'https://example.com/a.mp4', true);

    await Future.wait([model.saveNow(), model.saveNow()]);

    final decoded = jsonDecode(await File('${support.path}/downloads.json').readAsString());
    expect(decoded, isA<List>(),
        reason: 'Two overlapping writers used to be able to interleave and corrupt downloads.json');
  });

  test('Should delete the partial file when an entry is removed', () async {
    final partial = File('${temp.path}/quax-download-clip.mp4');
    await partial.writeAsBytes([1, 2, 3]);
    model.register('clip.mp4', 'https://example.com/clip.mp4', true);

    model.remove('clip.mp4');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(await partial.exists(), isFalse,
        reason: 'A paused/removed transfer kept its partial bytes in the cache forever');
  });

  test('Should delete the partial file when an entry is cancelled', () async {
    final partial = File('${temp.path}/quax-download-clip.mp4');
    await partial.writeAsBytes([1, 2, 3]);
    model.register('clip.mp4', 'https://example.com/clip.mp4', true);

    model.cancel('clip.mp4');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(await partial.exists(), isFalse,
        reason: 'Cancelling from the queue is a user request to reclaim the space');
  });

  test('Should ignore a corrupt video-cache ledger', () async {
    VideoCache.debugDirectoryOverride = temp;
    VideoCache().resetForTests();
    await File('${temp.path}/video_cache.json').writeAsString('{not json');

    await VideoCache().load();

    expect(VideoCache().count, 0,
        reason: 'A broken cache ledger means an empty cache, not a crash on the first video');
  });

  test('Should serialize concurrent video-cache saves into one valid ledger', () async {
    final cacheDir = Directory('${temp.path}/cache')..createSync();
    final incoming = Directory('${temp.path}/incoming')..createSync();
    VideoCache.debugDirectoryOverride = cacheDir;
    final cache = VideoCache()..resetForTests();
    final prefs = PrefServiceCache(cache: {optionVideoCacheLimitMb: 1024});
    final first = File('${incoming.path}/one.mp4')..writeAsBytesSync([1, 2, 3]);
    final second = File('${incoming.path}/two.mp4')..writeAsBytesSync([4, 5, 6]);

    await Future.wait([
      cache.put('https://video.twimg.com/one.mp4', first, prefs: prefs),
      cache.put('https://video.twimg.com/two.mp4', second, prefs: prefs),
    ]);

    final decoded = jsonDecode(await File('${cacheDir.path}/video_cache.json').readAsString());
    expect(decoded, isA<List>(),
        reason: 'Two overlapping ledger writers used to be able to delete the file entirely');
    expect((decoded as List), hasLength(2),
        reason: 'Each completed put() must survive the other writer; losing one leaves the clip '
            'on disk but outside the size limit and invisible after a restart');
  });
}
