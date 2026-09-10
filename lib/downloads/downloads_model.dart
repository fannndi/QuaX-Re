import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:quax/downloads/download_notifications.dart';

enum DownloadStatus { running, done, error }

/// One entry of the downloads queue / history. The item survives app
/// restarts through a small JSON ledger (Hentoid's queue.json idea), so failed
/// downloads can be retried and finished ones stay listed.
class DownloadQueueItem {
  final String fileName;
  final String url;
  final bool isVideo;
  final int receivedBytes;
  final int? totalBytes;
  final double speedMbPerSec;
  final DownloadStatus status;
  final String? error;

  const DownloadQueueItem({
    required this.fileName,
    required this.url,
    required this.isVideo,
    required this.receivedBytes,
    this.totalBytes,
    this.speedMbPerSec = 0,
    this.status = DownloadStatus.running,
    this.error,
  });

  double get receivedMb => receivedBytes / 1048576;
  double? get totalMb => totalBytes == null ? null : totalBytes! / 1048576;

  DownloadQueueItem copyWith({
    int? receivedBytes,
    int? totalBytes,
    double? speedMbPerSec,
    DownloadStatus? status,
    String? error,
    bool clearError = false,
  }) =>
      DownloadQueueItem(
        fileName: fileName,
        url: url,
        isVideo: isVideo,
        receivedBytes: receivedBytes ?? this.receivedBytes,
        totalBytes: totalBytes ?? this.totalBytes,
        speedMbPerSec: speedMbPerSec ?? this.speedMbPerSec,
        status: status ?? this.status,
        error: clearError ? null : (error ?? this.error),
      );

  Map<String, dynamic> toJson() => {
        'fileName': fileName,
        'url': url,
        'isVideo': isVideo,
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
        'status': status.name,
        'error': error,
      };

  factory DownloadQueueItem.fromJson(Map<String, dynamic> json) => DownloadQueueItem(
        fileName: json['fileName'] as String? ?? '',
        url: json['url'] as String? ?? '',
        isVideo: json['isVideo'] as bool? ?? false,
        receivedBytes: json['receivedBytes'] as int? ?? 0,
        totalBytes: json['totalBytes'] as int?,
        status: DownloadStatus.values.firstWhere((s) => s.name == json['status'],
            orElse: () => DownloadStatus.error),
        error: json['error'] as String?,
      );
}

/// The process-wide downloads store: live queue plus persisted history. Fed by
/// the streamed download runtime, saved to a JSON ledger in the app's support
/// directory so reopening the app keeps the queue and the failures.
class DownloadsModel extends Store<List<DownloadQueueItem>> {
  static final DownloadsModel _instance = DownloadsModel._();

  factory DownloadsModel() => _instance;

  DownloadsModel._() : super([]);

  bool _loaded = false;
  int _lastSaveAt = 0;

  // Each running download leaves its abort hook here; the queue screen is able
  // to pull it without owning the HTTP machinery.
  final Map<String, void Function()> _cancelHooks = {};
  final Set<String> _cancelled = {};

  // Hooks fired when a download lands at its destination: the Downloaded tab
  // re-scans the library folder through these.
  final Map<String, void Function()> _doneListeners = {};

  void addDoneListener(String key, void Function() listener) => _doneListeners[key] = listener;

  void removeDoneListener(String key) => _doneListeners.remove(key);

  Future<File> _ledgerFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'downloads.json'));
  }

  /// Loads the persisted history once per process. Running rows mean the app
  /// died mid-download: they become retryable errors, never silent resumes.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _ledgerFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return;
      final items = decoded
          .whereType<Map<String, dynamic>>()
          .map(DownloadQueueItem.fromJson)
          .where((item) => item.fileName.isNotEmpty && item.url.isNotEmpty)
          .map((item) => item.status == DownloadStatus.running
              ? item.copyWith(status: DownloadStatus.error, error: 'interrupted')
              : item)
          .toList();
      update(items, force: true);
    } catch (e) {
      debugPrint('DownloadsModel load failed: $e');
    }
  }

  Future<void> _save({bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastSaveAt < 3000) {
      return;
    }
    _lastSaveAt = now;
    try {
      final file = await _ledgerFile();
      await file.writeAsString(jsonEncode(state.map((e) => e.toJson()).toList()));
    } catch (e) {
      debugPrint('DownloadsModel save failed: $e');
    }
  }

  void register(String fileName, String url, bool isVideo) {
    _cancelled.remove(fileName);
    final existing = List.of(state);
    existing.removeWhere((item) => item.fileName == fileName);
    existing.insert(
        0,
        DownloadQueueItem(
            fileName: fileName, url: url, isVideo: isVideo, receivedBytes: 0, totalBytes: null));
    update(existing, force: true);
    _save(force: true);
  }

  void attachCancel(String fileName, void Function() abort) => _cancelHooks[fileName] = abort;

  void progress(String fileName, int receivedBytes, int? totalBytes, double speedBytesPerSec) {
    if (_cancelled.contains(fileName)) return;
    final updated = [
      for (final item in state)
        item.fileName == fileName
            ? item.copyWith(
                receivedBytes: receivedBytes, totalBytes: totalBytes, speedMbPerSec: speedBytesPerSec / 1048576)
            : item
    ];
    update(updated, force: true);
    DownloadsModel._pumpNotification(updated.firstWhere((e) => e.fileName == fileName));
    _save();
  }

  /// Seed for a resumed download: the bytes already on disk in the temp file.
  int resumeOffsetFor(String fileName) {
    for (final item in state) {
      if (item.fileName == fileName && item.status == DownloadStatus.running) {
        return item.receivedBytes;
      }
    }
    return 0;
  }

  bool isCancelled(String fileName) => _cancelled.contains(fileName);

  /// Re-opens a failed entry for a retry (keeps its partial bytes so the
  /// download can resume with a Range request).
  void startResume(String fileName) {
    _cancelled.remove(fileName);
    final updated = [
      for (final item in state)
        item.fileName == fileName
            ? item.copyWith(status: DownloadStatus.running, speedMbPerSec: 0, clearError: true)
            : item
    ];
    update(updated, force: true);
    _save(force: true);
  }

  void markDone(String fileName) {
    _cancelHooks.remove(fileName);
    final updated = [
      for (final item in state)
        item.fileName == fileName
            ? item.copyWith(status: DownloadStatus.done, clearError: true)
            : item
    ];
    update(updated, force: true);
    DownloadsModel._pumpFinalize(updated.firstWhere((e) => e.fileName == fileName));
    for (final listener in List.of(_doneListeners.values)) {
      try {
        listener();
      } catch (_) {}
    }
    _save(force: true);
  }

  /// A download failed: keep the entry (and its partial bytes) so the queue
  /// screen can retry it, possibly resuming.
  void fail(String fileName, {String? error}) {
    _cancelHooks.remove(fileName);
    final updated = [
      for (final item in state)
        item.fileName == fileName ? item.copyWith(status: DownloadStatus.error, error: error) : item
    ];
    update(updated, force: true);
    DownloadsModel._pumpNotification(updated.firstWhere((e) => e.fileName == fileName));
    _save(force: true);
  }

  /// User-initiated abort from the queue screen: the entry and its partial
  /// bytes go away entirely.
  void cancel(String fileName) {
    _cancelled.add(fileName);
    _cancelHooks.remove(fileName)?.call();
    _cancelHooks.remove(fileName);
    final updated = state.where((item) => item.fileName != fileName).toList();
    update(updated, force: true);
    DownloadsModel._clearIfIdle(updated);
    _save(force: true);
  }

  void remove(String fileName) {
    final updated = state.where((item) => item.fileName != fileName).toList();
    update(updated, force: true);
    DownloadsModel._clearIfIdle(updated);
    _save(force: true);
  }

  void clearFinished() {
    final updated = state.where((item) => item.status != DownloadStatus.done).toList();
    update(updated, force: true);
    _save(force: true);
  }

  static void _pumpNotification(DownloadQueueItem item) => DownloadNotifications.update(item);

  static void _pumpFinalize(DownloadQueueItem item) => DownloadNotifications.finalize(item);

  static void _clearIfIdle(List<DownloadQueueItem> items) {
    if (!items.any((item) => item.status == DownloadStatus.running)) {
      DownloadNotifications.clear();
    }
  }
}
