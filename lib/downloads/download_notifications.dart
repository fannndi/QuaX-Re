import 'package:flutter/services.dart';
import 'package:quax/downloads/connectivity_watcher.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/generated/l10n.dart';

/// The foreground-service notification: it keeps the app process alive while a
/// transfer runs (downloads survive backgrounding) and offers Pause/Cancel
/// actions whose taps come back through the same channel.
class DownloadNotifications {
  static const _channel = MethodChannel('browser_resolver');
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
  /// status is a hint the transfer ended: stop the service when nothing runs
  /// and let the connectivity watcher look after failed entries.
  static Future<void> update(DownloadQueueItem item) async {
    if (!_ready) return;

    if (item.status != DownloadStatus.running) {
      await _stopIfIdle();
      ConnectivityWatcher().scheduleCheck();
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastNotifyAt < 900) return;
    _lastNotifyAt = now;
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

  static Future<void> _stopIfIdle() async {
    final remaining = DownloadsModel().state.where((e) => e.status == DownloadStatus.running).length;
    if (remaining == 0) await clear();
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
