import 'package:flutter/services.dart';
import 'package:quax/constants.dart';
import 'package:quax/downloads/connectivity_watcher.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/generated/l10n.dart';

/// The foreground-service notification: it keeps the app process alive while a
/// transfer runs (downloads survive backgrounding) and offers Pause/Cancel
/// actions whose taps come back through the same channel.
class DownloadNotifications {
  static const _channel = quaxMethodChannel;
  static bool _ready = false;
  static int _lastNotifyAt = 0;

  static Future<void> ensure() async {
    if (_ready) return;
    _ready = true;
    _channel.setMethodCallHandler(_onAction);

    try {
      await _channel.invokeMethod('requestNotificationsPermission');
    } catch (_) {
      // Notification permission is a nicety; transfers run regardless.
    }
  }

  static Future<void> _onAction(MethodCall call) async {
    if (call.method != 'onDownloadAction') return;

    final args = call.arguments as Map?;
    final fileName = args?['fileName'] as String?;
    final action = args?['action'] as String?;
    if (fileName == null || fileName.isEmpty) return;

    final queue = DownloadsModel();
    switch (action) {
      case 'pause':
        queue.pause(fileName);
      case 'cancel':
        queue.cancel(fileName);
    }
  }

  /// Mirrors a running download; throttled so the bar updates ~1×/s. Any other
  /// status is a hint the transfer ended: stop the service once nothing is
  /// left to run, and let the connectivity watcher look after failed entries.
  static Future<void> update(DownloadQueueItem item) async {
    if (!_ready) return;

    if (item.status != DownloadStatus.running) {
      // A failed attempt is followed by a retry seconds later. Dropping the
      // service here left the backoff window unprotected, and Android 12+
      // refuses to start it again from the background — so the retry ran in a
      // cached process that the system is free to freeze or kill.
      final busy = DownloadsModel().state.any((entry) =>
          entry.status == DownloadStatus.running || entry.status == DownloadStatus.queued);
      if (!busy) {
        await clear();
        ConnectivityWatcher().scheduleCheck();
      }
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastNotifyAt < 900) return;
    _lastNotifyAt = now;
    await _push(item);
  }

  /// Called the moment an entry becomes the running one, before the socket is
  /// opened. The foreground service has to cover DNS, TLS and the first byte,
  /// not only the part of the transfer that has a progress bar.
  static Future<void> start(DownloadQueueItem item) async {
    if (!_ready) return;
    _lastNotifyAt = DateTime.now().millisecondsSinceEpoch;
    await _push(item);
  }

  /// Final tick for a download: with an idle queue, drop the bar entirely.
  static Future<void> finalize(DownloadQueueItem item) async {
    if (!_ready) return;
    _lastNotifyAt = 0;

    final remaining = DownloadsModel().state.where((e) => e.status == DownloadStatus.running).length;
    if (remaining == 0) {
      await clear();
      return;
    }
    await _push(item);
  }

  /// The queue went idle (cancel, fail or finish): drop the bar.
  static Future<void> clear() async {
    if (!_ready) return;
    try {
      await _channel.invokeMethod('stopDownloadNotification');
    } catch (_) {
      // The service was already stopped (or no binding in tests).
    }
  }

  static Future<void> _push(DownloadQueueItem item) async {
    final l10n = L10n.current;
    final body = '${item.receivedMb.toStringAsFixed(1)} MB'
        '${item.totalMb == null ? '' : ' / ${item.totalMb!.toStringAsFixed(1)} MB'}'
        '\u00b7 ${item.speedMbPerSec.toStringAsFixed(1)} MB/s';
    final percent = (item.totalBytes == null || item.totalBytes == 0)
        ? 0
        : ((item.receivedBytes / item.totalBytes!) * 100).round().clamp(0, 100);

    try {
      await _channel.invokeMethod('downloadNotification', {
        'title': item.fileName,
        'body': body,
        'percent': percent,
        'fileName': item.fileName,
        'pauseLabel': l10n.pause,
        'cancelLabel': l10n.cancel,
      });
    } catch (_) {
      // The progress bar is best-effort; the transfer itself is unaffected.
    }
  }
}
