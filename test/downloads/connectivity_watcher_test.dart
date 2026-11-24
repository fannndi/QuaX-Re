import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pref/pref.dart';
import 'package:quax/downloads/connectivity_watcher.dart';
import 'package:quax/downloads/downloads_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final queue = DownloadsModel();
  final watcher = ConnectivityWatcher();
  late Directory support;

  setUp(() {
    support = Directory.systemTemp.createTempSync('quax-connectivity-');
    DownloadsModel.debugDirectoryOverride = support;
    queue.resetForTests();
    watcher.resetForTests();
    ConnectivityWatcher.debugForeground = true;
    ConnectivityWatcher.debugReachable = () async => true;
  });

  tearDown(() async {
    watcher.resetForTests();
    await queue.flush();
    queue.resetForTests();
    DownloadsModel.debugDirectoryOverride = null;
    support.deleteSync(recursive: true);
    ConnectivityWatcher.debugForeground = null;
    ConnectivityWatcher.debugReachable = null;
    ConnectivityWatcher.debugResume = null;
  });

  test('Should not auto-resume while the app is backgrounded', () async {
    final prefs = PrefServiceCache();
    queue.register('clip.mp4', 'https://x/clip.mp4', true);
    queue.startRunning('clip.mp4');
    queue.fail('clip.mp4', error: 'timeout');
    final resumed = <String>[];
    ConnectivityWatcher.debugResume = (item, prefs) =>
        resumed.add(item.fileName);
    ConnectivityWatcher.debugForeground = false;
    watcher.ensure(prefs);

    await watcher.debugProbeNow();

    expect(
      resumed,
      isEmpty,
      reason: 'A cached process must not start a new foreground-service transfer in the background',
    );
    expect(queue.itemFor('clip.mp4')?.status, DownloadStatus.error);
  });

  test('Should give a replacement attempt a fresh auto-resume budget', () async {
    final prefs = PrefServiceCache();
    queue.register('clip.mp4', 'https://x/old.mp4', true);
    queue.startRunning('clip.mp4');
    queue.fail('clip.mp4', error: 'timeout');
    final first = queue.itemFor('clip.mp4')!;
    final resumed = <String>[];
    ConnectivityWatcher.debugResume = (item, prefs) =>
        resumed.add(item.attemptId);
    watcher.ensure(prefs);

    for (var i = 0; i < 3; i++) {
      await watcher.debugProbeNow();
    }
    await watcher.debugProbeNow();
    expect(
      resumed,
      [first.attemptId, first.attemptId, first.attemptId],
      reason:
          'One exhausted attempt must stop consuming the per-run retry budget',
    );

    queue.register('clip.mp4', 'https://x/new.mp4', true);
    queue.startRunning('clip.mp4');
    queue.fail('clip.mp4', error: 'timeout');
    final replacement = queue.itemFor('clip.mp4')!;
    await watcher.debugProbeNow();

    expect(
      resumed.last,
      replacement.attemptId,
      reason: 'Re-downloading the same name must not inherit the replaced attempt counter',
    );
  });

  test(
    'Should auto-resume a retryable failure after the app returns foreground',
    () async {
      final prefs = PrefServiceCache();
      queue.register('clip.mp4', 'https://x/clip.mp4', true);
      queue.startRunning('clip.mp4');
      queue.fail('clip.mp4', error: 'timeout');
      final resumed = <String>[];
      ConnectivityWatcher.debugResume = (item, prefs) =>
          resumed.add(item.fileName);
      watcher.ensure(prefs);

      await watcher.debugProbeNow();

      expect(resumed, [
        'clip.mp4',
      ], reason: 'Foreground recovery still uses the normal queue path');
    },
  );
}
