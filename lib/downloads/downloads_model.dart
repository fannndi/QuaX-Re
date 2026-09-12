import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:quax/downloads/download_notifications.dart';

/// queued: waiting for its turn (downloads run one at a time, so parallel
/// transfers never fight over the connection); paused: held by the user with
/// its partial bytes kept for a later resume.
enum DownloadStatus { queued, running, paused, done, error }

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

  /// Finished rows kept in the ledger; older ones are pruned on the next
  /// enqueue so the history cannot grow forever.
  static const _maxFinishedHistory = 50;

  // Each running download leaves its abort hook here; the queue screen is able
  // to pull it without owning the HTTP machinery.
  final Map<String, void Function()> _cancelHooks = {};
  final Set<String> _cancelled = {};
  final Set<String> _paused = {};

  // Hooks fired when a download lands at its destination: the Downloaded tab
  // re-scans the library folder through these.
  final Map<String, void Function()> _doneListeners = {};

  void addDoneListener(String key, void Function() listener) => _doneListeners[key] = listener;

  void removeDoneListener(String key) => _doneListeners.remove(key);

  Future<File> _ledgerFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'downloads.json'));
  }

  /// Loads the persisted history once per process. Entries that were waiting
  /// or running mean the app died mid-download (or was force-closed): they come
  /// back as paused with their partial bytes, ready for Resume-all.
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
          .map((item) => item.status == DownloadStatus.running || item.status == DownloadStatus.queued
              ? item.copyWith(status: DownloadStatus.paused, speedMbPerSec: 0)
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
    _paused.remove(fileName);
    final existing = List.of(state);
    existing.removeWhere((item) => item.fileName == fileName);
    existing.insert(
        0,
        DownloadQueueItem(
            fileName: fileName,
            url: url,
            isVideo: isVideo,
            receivedBytes: 0,
            totalBytes: null,
            status: DownloadStatus.queued));
    _pruneFinished(existing);
    update(existing, force: true);
    _save(force: true);
  }

  /// Bounds the finished history so the ledger stays small and startup fast:
  /// at most [_maxFinishedHistory] done rows, newest first.
  void _pruneFinished(List<DownloadQueueItem> items) {
    var finished = items.where((item) => item.status == DownloadStatus.done).length;
    if (finished <= _maxFinishedHistory) return;

    items.removeWhere((item) {
      if (item.status != DownloadStatus.done || finished <= _maxFinishedHistory) return false;
      finished--;
      return true;
    });
  }

  bool contains(String fileName) => state.any((item) => item.fileName == fileName);

  /// The live entry for [fileName], or null when it is not in the queue.
  DownloadQueueItem? itemFor(String fileName) {
    final index = _indexOf(fileName);
    return index < 0 ? null : state[index];
  }

  /// True while the entry waits, runs or is held — re-requesting a download
  /// for such a file must not start a second transfer.
  bool isActive(String fileName) {
    final item = itemFor(fileName);
    return item != null &&
        (item.status == DownloadStatus.queued ||
            item.status == DownloadStatus.running ||
            item.status == DownloadStatus.paused);
  }

  /// Test hook: drops the in-memory queue (the on-disk ledger is untouched).
  @visibleForTesting
  void resetForTests() {
    _cancelHooks.clear();
    _cancelled.clear();
    _paused.clear();
    _doneListeners.clear();
    update([], force: true);
  }

  int _indexOf(String fileName) => state.indexWhere((item) => item.fileName == fileName);

  void attachCancel(String fileName, void Function() abort) => _cancelHooks[fileName] = abort;

  void progress(String fileName, int receivedBytes, int? totalBytes, double speedBytesPerSec) {
    if (_cancelled.contains(fileName) || _paused.contains(fileName)) return;
    final index = _indexOf(fileName);
    if (index < 0) return;

    final updated = [
      for (final item in state)
        item.fileName == fileName
            ? item.copyWith(
                receivedBytes: receivedBytes, totalBytes: totalBytes, speedMbPerSec: speedBytesPerSec / 1048576)
            : item
    ];
    update(updated, force: true);
    DownloadsModel._pumpNotification(updated[index]);
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

  bool isPaused(String fileName) => _paused.contains(fileName);

  /// Holds the whole queue: the running transfer is paused in place and the
  /// waiting ones move to paused too, so Resume-all can bring every entry back
  /// in order (each resuming from its partial bytes).
  void pauseAll() {
    final names = state
        .where((item) => item.status == DownloadStatus.running || item.status == DownloadStatus.queued)
        .map((item) => item.fileName)
        .toList();
    for (final name in names) {
      pause(name);
    }
  }

  /// Holds a running download: the transfer aborts, but the entry and its
  /// partial bytes stay, so [requeue]-ing it later resumes with a Range request.
  void pause(String fileName) {
    final index = _indexOf(fileName);
    if (index < 0) return;

    _paused.add(fileName);
    _cancelHooks.remove(fileName)?.call();

    final updated = [
      for (final item in state)
        item.fileName == fileName
            ? item.copyWith(status: DownloadStatus.paused, speedMbPerSec: 0)
            : item
    ];
    update(updated, force: true);
    DownloadsModel._pumpNotification(updated[index]);
    _save(force: true);
  }

  /// Hands the next turn to a waiting entry: it becomes the one running
  /// download (its partial bytes are kept for a resume).
  void startRunning(String fileName) {
    _cancelled.remove(fileName);
    _paused.remove(fileName);
    final index = _indexOf(fileName);
    if (index < 0) return;

    final updated = [
      for (final item in state)
        item.fileName == fileName
            ? item.copyWith(status: DownloadStatus.running, speedMbPerSec: 0, clearError: true)
            : item
    ];
    update(updated, force: true);
    _save(force: true);
  }

  /// Puts a failed or paused entry back at the waiting line (a retry/resume
  /// goes through the same one-at-a-time queue).
  void requeue(String fileName) {
    _cancelled.remove(fileName);
    _paused.remove(fileName);
    final index = _indexOf(fileName);
    if (index < 0) return;

    final updated = [
      for (final item in state)
        item.fileName == fileName
            ? item.copyWith(status: DownloadStatus.queued, speedMbPerSec: 0, clearError: true)
            : item
    ];
    update(updated, force: true);
    _save(force: true);
  }

  void markDone(String fileName) {
    _cancelHooks.remove(fileName);
    _paused.remove(fileName);
    final index = _indexOf(fileName);
    if (index < 0) return;

    final updated = [
      for (final item in state)
        item.fileName == fileName
            ? item.copyWith(status: DownloadStatus.done, clearError: true)
            : item
    ];
    update(updated, force: true);
    DownloadsModel._pumpFinalize(updated[index]);
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
    _paused.remove(fileName);
    final index = _indexOf(fileName);
    if (index < 0) return;

    final updated = [
      for (final item in state)
        item.fileName == fileName ? item.copyWith(status: DownloadStatus.error, error: error) : item
    ];
    update(updated, force: true);
    DownloadsModel._pumpNotification(updated[index]);
    _save(force: true);
  }

  /// User-initiated abort from the queue screen: the entry and its partial
  /// bytes go away entirely.
  void cancel(String fileName) {
    _cancelled.add(fileName);
    _paused.remove(fileName);
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
