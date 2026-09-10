import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:quax/downloads/downloads_model.dart';

/// Hentoid-style progress on Android's notification bar: one ongoing
/// notification that mirrors the newest running download (percent, moved size
/// and speed) and is cleared as soon as the queue goes idle.
class DownloadNotifications {
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static int _lastNotifyAt = 0;

  static const int _id = 4711;
  static const String _channelId = 'downloads';
  static const String _channelName = 'Downloads';
  static const String _channelDescription = 'Media download progress.';

  static Future<void> ensure() async {
    if (_ready) return;
    _ready = true;
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await _plugin.initialize(settings: settings);
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('DownloadNotifications init failed: $e');
      _ready = false;
    }
  }

  /// Mirrors a running download; throttled so the bar updates ~1×/s.
  static Future<void> update(DownloadQueueItem item) async {
    if (!_ready) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastNotifyAt < 900 && !item.done) return;
    _lastNotifyAt = now;

    final title = item.isVideo ? 'Downloading video…' : 'Downloading image…';
    final body = '${item.receivedMb.toStringAsFixed(1)} MB'
        '${item.totalMb == null ? '' : ' / ${item.totalMb!.toStringAsFixed(1)} MB'}'
        '\u00b7 ${item.speedMbPerSec.toStringAsFixed(1)} MB/s';

    final percent = (item.totalMb == null || item.totalMb == 0)
        ? 0
        : ((item.receivedMb / item.totalMb!) * 100).round().clamp(0, 100);

    await _push(title, body, percent: percent);
  }

  /// Final tick for a download: with an idle queue, drop the bar entirely.
  static Future<void> finalize(DownloadQueueItem item) async {
    if (!_ready) return;
    _lastNotifyAt = 0;

    final remaining = DownloadsModel().state.where((e) => !e.done).length;
    if (remaining == 0) {
      await clear();
      return;
    }
    await _push('Downloads', '${item.fileName} finished', percent: 100);
  }

  /// The queue went idle (cancel, fail or finish): drop the bar.
  static Future<void> clear() async {
    try {
      if (_ready) {
        await _plugin.cancel(id: _id);
      }
    } catch (e) {
      debugPrint('DownloadNotifications clear failed: $e');
    }
  }

  static Future<void> _push(String title, String body, {required int percent}) async {
    try {
      await _plugin.show(
        id: _id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            onlyAlertOnce: true,
            ongoing: true,
            showProgress: true,
            maxProgress: 100,
            progress: percent,
            indeterminate: false,
          ),
        ),
      );
    } catch (e) {
      debugPrint('DownloadNotifications push failed: $e');
    }
  }
}
