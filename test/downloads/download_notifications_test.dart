import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quax/downloads/download_notifications.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/generated/l10n.dart';

void main() {
  test(
    'Should keep the file name out of the visible notification title',
    () async {
      await L10n.load(const Locale('en'));
      final item = DownloadQueueItem(
        fileName: 'private-account-media.mp4',
        url: 'https://x/private',
        isVideo: true,
        receivedBytes: 1,
      );

      final payload = DownloadNotifications.debugPayload(item);

      expect(
        payload['title'],
        isNot(contains(item.fileName)),
        reason: 'Lock-screen notifications must not reveal private media names',
      );
      expect(
        payload['body'],
        isNot(contains(item.fileName)),
        reason: 'The visible progress body contains sizes only',
      );
      expect(
        payload['attemptId'],
        item.attemptId,
        reason:
            'Notification actions target one attempt, not a reusable file name',
      );
    },
  );

  test('Should keep the worker behind the readiness barrier until native confirms', () async {
    final gate = DownloadServiceReadinessGate();
    final request = Completer<void>();
    var completed = false;

    final waiting = gate
        .wait(
          request: () => request.future,
          timeout: const Duration(seconds: 1),
        )
        .then((ready) {
          completed = true;
          return ready;
        });
    await Future<void>.delayed(Duration.zero);

    expect(
      completed,
      isFalse,
      reason: 'The socket must not open merely because startForegroundService was requested',
    );
    gate.ready();
    expect(
      await waiting,
      isTrue,
      reason:
          'Only the native post-startForeground callback releases the transfer',
    );
  });

  test(
    'Should refresh an already-ready service before the next socket opens',
    () async {
      final gate = DownloadServiceReadinessGate()..ready();
      var requested = false;

      final ready = await gate.wait(
        request: () async => requested = true,
        refreshIfReady: true,
      );

      expect(ready, isTrue);
      expect(
        requested,
        isTrue,
        reason: 'The next attempt needs its own notification action identity before transfer starts',
      );
    },
  );

  test('Should report refusal and allow a later readiness attempt', () async {
    final gate = DownloadServiceReadinessGate();
    final refused = gate.wait(
      request: () => Completer<void>().future,
      timeout: const Duration(seconds: 1),
    );
    gate.failed();

    expect(
      await refused,
      isFalse,
      reason: 'A foreground-service refusal must pause the worker instead of running unprotected',
    );
    final retry = gate.wait(
      request: () => Completer<void>().future,
      timeout: const Duration(seconds: 1),
    );
    gate.ready();
    expect(
      await retry,
      isTrue,
      reason: 'A later manual resume can establish foreground protection again',
    );
  });

  test('Should pause the queue when native readiness fails', () async {
    final support = Directory.systemTemp.createTempSync('quax-service-');
    final queue = DownloadsModel()..resetForTests();
    addTearDown(() async {
      await queue.flush();
      DownloadsModel().resetForTests();
      DownloadsModel.debugDirectoryOverride = null;
      DownloadNotifications.resetForTests();
      support.deleteSync(recursive: true);
    });
    DownloadsModel.debugDirectoryOverride = support;
    queue.register('clip.mp4', 'https://x/clip.mp4', true);
    queue.register('next.mp4', 'https://x/next.mp4', true);
    DownloadNotifications.debugStart = (_) async =>
        throw const DownloadServiceUnavailableException();

    final started = await queue.startRunning('clip.mp4');

    expect(
      started,
      isFalse,
      reason:
          'The worker must not open a socket when foreground readiness fails',
    );
    expect(
      queue.itemFor('clip.mp4')?.status,
      DownloadStatus.paused,
      reason: 'A service refusal parks the transfer for a later manual resume',
    );
    expect(
      queue.serviceUnavailable,
      isTrue,
      reason: 'The worker must stop instead of retrying startup for every queued row',
    );
    queue.requeue('clip.mp4');
    expect(
      queue.serviceUnavailable,
      isFalse,
      reason:
          'A manual resume may try establishing foreground protection again',
    );
  });

  test('Should fail closed when the native readiness callback times out', () async {
    final gate = DownloadServiceReadinessGate();
    final waiting = gate.wait(
      request: () => Completer<void>().future,
      timeout: const Duration(milliseconds: 10),
    );

    expect(
      await waiting,
      isFalse,
      reason:
          'A missing callback is not proof that the foreground service started',
    );
    expect(
      gate.isReady,
      isFalse,
      reason:
          'Timing out must not leave a false ready state for the next transfer',
    );
  });
}
