import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:quax/constants.dart';
import 'package:quax/downloads/connectivity_watcher.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/generated/l10n.dart';

class DownloadServiceUnavailableException implements Exception {
  const DownloadServiceUnavailableException();
}

/// Native readiness is a callback, not the return value of the start request:
/// Android accepts startForegroundService before the service has called
/// startForeground. This gate fails closed if that callback never arrives.
class DownloadServiceReadinessGate {
  bool _ready = false;
  Completer<bool>? _pending;

  bool get isReady => _ready;

  Future<bool> wait({
    required Future<void> Function() request,
    Duration timeout = const Duration(seconds: 8),
    bool refreshIfReady = false,
  }) async {
    if (_ready) {
      if (refreshIfReady) await request();
      return true;
    }
    if (_pending != null) {
      try {
        return await _pending!.future.timeout(timeout);
      } on TimeoutException {
        failed();
        return false;
      }
    }

    final pending = Completer<bool>();
    _pending = pending;
    unawaited(Future<void>.sync(request).catchError((Object _) => failed()));
    try {
      return await pending.future.timeout(timeout);
    } on TimeoutException {
      failed();
      return false;
    }
  }

  void ready() {
    _ready = true;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete(true);
  }

  void failed() {
    _ready = false;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
  }
}

/// The foreground-service notification: it keeps the app process alive while a
/// transfer runs (downloads survive backgrounding) and offers Pause/Cancel
/// actions whose taps come back through the same channel.
class DownloadNotifications {
  static const _channel = quaxMethodChannel;
  static bool _initialized = false;
  static int _lastNotifyAt = 0;
  static final _readiness = DownloadServiceReadinessGate();

  @visibleForTesting
  static Future<void> Function(DownloadQueueItem item)? debugStart;

  @visibleForTesting
  static Map<String, Object?> debugPayload(DownloadQueueItem item) =>
      _payload(item);

  @visibleForTesting
  static void resetForTests() {
    _readiness.failed();
    _initialized = false;
    _lastNotifyAt = 0;
    debugStart = null;
  }

  static Future<void> ensure() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_onNativeCall);

    try {
      await _channel.invokeMethod('requestNotificationsPermission');
    } catch (_) {
      // Notification permission is a nicety; transfers run regardless.
    }
  }

  static Future<void> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onDownloadServiceReady':
        _readiness.ready();
        return;
      case 'onDownloadServiceFailed':
        _readiness.failed();
        final queue = DownloadsModel();
        queue.markServiceUnavailable();
        for (final item in queue.state.where(
          (item) => item.status == DownloadStatus.running,
        )) {
          queue.pause(item.fileName, attemptId: item.attemptId);
        }
        return;
      default:
        await _onAction(call);
    }
  }

  static Future<void> _onAction(MethodCall call) async {
    if (call.method != 'onDownloadAction') return;

    final args = call.arguments as Map?;
    final fileName = args?['fileName'] as String?;
    final attemptId = args?['attemptId'] as String?;
    final action = args?['action'] as String?;
    if (fileName == null || fileName.isEmpty) return;

    final queue = DownloadsModel();
    switch (action) {
      case 'pause':
        queue.pause(fileName, attemptId: attemptId);
      case 'cancel':
        queue.cancel(fileName, attemptId: attemptId);
    }
  }

  /// Mirrors a running download; throttled so the bar updates ~1×/s. Any other
  /// status is a hint the transfer ended, but the service is *not* stopped
  /// here: the worker retries a transient failure seconds later and Android
  /// 12+ refuses to start the service again from the background. It is stopped
  /// by [clear]/[finalize] once the queue is genuinely idle.
  static Future<void> update(DownloadQueueItem item) async {
    if (!_initialized || !_readiness.isReady) return;

    if (item.status != DownloadStatus.running) {
      // A failed attempt is followed by a retry inside the same worker, so the
      // backoff has to stay protected; the watcher may also bring the entry
      // back later.
      ConnectivityWatcher().scheduleCheck();
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
    final override = debugStart;
    if (override != null) return override(item);
    if (!Platform.isAndroid) return;
    await ensure();
    _lastNotifyAt = DateTime.now().millisecondsSinceEpoch;
    Future<void> request() => _channel.invokeMethod<void>(
      'startDownloadNotification',
      _payload(item),
    );
    final ready = await _readiness.wait(request: request, refreshIfReady: true);
    if (!ready) throw const DownloadServiceUnavailableException();
  }

  /// Final tick for a download: with an idle queue, drop the bar entirely.
  static Future<void> finalize(DownloadQueueItem item) async {
    if (!_initialized || !_readiness.isReady) return;
    _lastNotifyAt = 0;

    // A queued entry is about to become the running one; clearing the service
    // here would leave that transfer unprotected for its whole connection
    // setup, which is exactly the window Android refuses to re-open.
    final busy = DownloadsModel().state.any(
      (e) =>
          e.status == DownloadStatus.running ||
          e.status == DownloadStatus.queued,
    );
    if (!busy) {
      await clear();
      return;
    }
    await _push(item);
  }

  /// The queue went idle (cancel, fail or finish): drop the bar.
  static Future<void> clear() async {
    if (!_initialized) return;
    _readiness.failed();
    try {
      await _channel.invokeMethod('stopDownloadNotification');
    } catch (_) {
      // The service was already stopped (or no binding in tests).
    }
  }

  static Map<String, Object?> _payload(DownloadQueueItem item) {
    final l10n = L10n.current;
    final body =
        '${item.receivedMb.toStringAsFixed(1)} MB'
        '${item.totalMb == null ? '' : ' / ${item.totalMb!.toStringAsFixed(1)} MB'}'
        '\u00b7 ${item.speedMbPerSec.toStringAsFixed(1)} MB/s';
    final percent = (item.totalBytes == null || item.totalBytes == 0)
        ? 0
        : ((item.receivedBytes / item.totalBytes!) * 100).round().clamp(0, 100);
    return {
      'title': l10n.downloads,
      'body': body,
      'percent': percent,
      'fileName': item.fileName,
      'attemptId': item.attemptId,
      'pauseLabel': l10n.pause,
      'cancelLabel': l10n.cancel,
    };
  }

  static Future<void> _push(DownloadQueueItem item) async {
    try {
      await _channel.invokeMethod('downloadNotification', _payload(item));
    } catch (_) {
      // The progress bar is best-effort; the transfer itself is unaffected.
    }
  }
}
