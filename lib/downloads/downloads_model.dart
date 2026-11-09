import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:quax/downloads/download_notifications.dart';
import 'package:quax/downloads/download_paths.dart';
import 'package:quax/utils/atomic_file.dart';

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
  // Where the file actually landed. Duplicate names get a timestamp suffix,
  // so the queue row cannot assume libraryPath/fileName still points at it.
  final String? savedPath;

  const DownloadQueueItem({
    required this.fileName,
    required this.url,
    required this.isVideo,
    required this.receivedBytes,
    this.totalBytes,
    this.speedMbPerSec = 0,
    this.status = DownloadStatus.running,
    this.error,
    this.savedPath,
  });

  double get receivedMb => receivedBytes / 1048576;
  double? get totalMb => totalBytes == null ? null : totalBytes! / 1048576;

  DownloadQueueItem copyWith({
    int? receivedBytes,
    int? totalBytes,
    double? speedMbPerSec,
    DownloadStatus? status,
    String? error,
    String? savedPath,
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
        savedPath: savedPath ?? this.savedPath,
      );

  Map<String, dynamic> toJson() => {
        'fileName': fileName,
        'url': url,
        'isVideo': isVideo,
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
        'status': status.name,
        'error': error,
        'savedPath': savedPath,
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
        savedPath: json['savedPath'] as String?,
      );
}

/// The process-wide downloads store: live queue plus persisted history. Fed by
/// the streamed download runtime, saved to a JSON ledger in the app's support
/// directory so reopening the app keeps the queue and the failures.
class DownloadsModel extends Store<List<DownloadQueueItem>> {
  static final DownloadsModel _instance = DownloadsModel._();

  factory DownloadsModel() => _instance;

  DownloadsModel._() : super([]);

  /// Test seam: the production ledger lives in the app support directory,
  /// which path_provider cannot resolve in the unit-test binary.
  @visibleForTesting
  static Directory? debugDirectoryOverride;

  bool _loaded = false;
  Future<void>? _writeInFlight;
  bool _dirty = false;
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
    final dir = debugDirectoryOverride ?? await getApplicationSupportDirectory();
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
    // Progress updates arrive several times a second; status changes are
    // forced. The throttle only applies to progress, never to serialization.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastSaveAt < 1500) return;
    _lastSaveAt = now;

    if (_writeInFlight != null) {
      // A write is already running: mark the state dirty so that loop writes
      // again. Dropping this call was how markDone/cancel/pause were lost.
      _dirty = true;
      return;
    }

    _writeInFlight = _writeLoop();
    try {
      await _writeInFlight;
      // Close the window between the loop's last dirty check and this clear.
      while (_dirty) {
        _dirty = false;
        await _writeLoop();
      }
    } finally {
      _writeInFlight = null;
    }
  }

  Future<void> _writeLoop() async {
    do {
      _dirty = false;
      try {
        final file = await _ledgerFile();
        await writeAtomically(file, jsonEncode(state.map((e) => e.toJson()).toList()));
      } catch (e) {
        debugPrint('DownloadsModel save failed: $e');
      }
    } while (_dirty);
  }

  /// Test hook: waits for a forced save, including a write that was already
  /// in flight when the call arrived.
  @visibleForTesting
  Future<void> saveNow() async {
    while (true) {
      await _save(force: true);
      final inFlight = _writeInFlight;
      if (inFlight == null) return;
      await inFlight;
    }
  }

  void register(String fileName, String url, bool isVideo) {
    _cancelled.remove(fileName);
    _paused.remove(fileName);
    final existing = List.of(state);
    existing.removeWhere((item) => item.fileName == fileName);
    // Appended: the list reads top-to-bottom exactly as transfers run, so
    // dragging an entry changes its execution order.
    existing.add(DownloadQueueItem(
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

  /// The next transfer the worker should run: the first waiting entry, i.e.
  /// the topmost one in the queue screen.
  DownloadQueueItem? get nextQueued {
    for (final item in state) {
      if (item.status == DownloadStatus.queued) return item;
    }
    return null;
  }

  /// Moves an entry to another position (drag & drop); waiting entries then run
  /// in their new order.
  /// Moves the row at [oldIndex] to [newIndex], both in the coordinates
  /// ReorderableListView's `onReorderItem` hands over: the target index is
  /// already counted after the source row has been taken out, so there is no
  /// "shift down" adjustment to make here.
  void moveItem(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= state.length) return;

    final updated = List.of(state);
    final item = updated.removeAt(oldIndex);
    updated.insert(newIndex.clamp(0, updated.length), item);
    update(updated, force: true);
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
    _writeInFlight = null;
    _dirty = false;
    _lastSaveAt = 0;
    _loaded = false;
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

  /// The worker has finished with [fileName] (success, failure, pause or
  /// cancel). The live flags are only read while a transfer is in flight, so
  /// clearing them here keeps the sets from growing for the app's lifetime.
  void clearTransient(String fileName) {
    _cancelled.remove(fileName);
    _paused.remove(fileName);
  }

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
  ///
  /// [_paused] is set *before* the abort hook runs, because the hook is only
  /// attached once [_downloadToTemp] has done its first awaits (a temporary
  /// directory, the cache lookup). Pausing in that window used to find no hook,
  /// so nothing aborted the socket: the entry showed "paused" and stopped
  /// updating while bytes kept flowing until the next pause or cancel.
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

  /// Rewrites the paths of finished entries after the library moved. The
  /// stored path is what the done card opens; leaving it on the old root made
  /// every finished row point at a file that is no longer there.
  void relocateSavedPaths(String oldRoot, String newRoot) {
    if (oldRoot.isEmpty || newRoot.isEmpty || p.equals(oldRoot, newRoot)) return;

    var changed = false;
    final updated = <DownloadQueueItem>[];
    for (final item in state) {
      final saved = item.savedPath;
      if (saved != null && p.isWithin(oldRoot, saved)) {
        updated.add(item.copyWith(savedPath: p.join(newRoot, p.relative(saved, from: oldRoot))));
        changed = true;
      } else {
        updated.add(item);
      }
    }
    if (!changed) return;
    update(updated);
    _save(force: true);
  }

  void markDone(String fileName, {String? savedPath}) {    _cancelHooks.remove(fileName);
    _paused.remove(fileName);
    final index = _indexOf(fileName);
    if (index < 0) return;

    final updated = [
      for (final item in state)
        item.fileName == fileName
            ? item.copyWith(status: DownloadStatus.done, clearError: true, savedPath: savedPath)
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
    unawaited(deletePartial(fileName));
    final updated = state.where((item) => item.fileName != fileName).toList();
    update(updated, force: true);
    DownloadsModel._clearIfIdle(updated);
    _save(force: true);
  }

  void remove(String fileName) {
    // A running transfer must be aborted before its partial file is unlinked;
    // otherwise the worker keeps writing to an unlinked path.
    if (itemFor(fileName)?.status == DownloadStatus.running) {
      cancel(fileName);
      return;
    }
    unawaited(deletePartial(fileName));
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
