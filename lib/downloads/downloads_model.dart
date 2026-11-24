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
import 'package:uuid/uuid.dart';

/// queued: waiting for its turn (downloads run one at a time, so parallel
/// transfers never fight over the connection); paused: held by the user with
/// its partial bytes kept for a later resume.
enum DownloadStatus { queued, running, paused, done, error }

/// One entry of the downloads queue / history. The item survives app
/// restarts through a small JSON ledger (Hentoid's queue.json idea), so failed
/// downloads can be retried and finished ones stay listed.
class DownloadQueueItem {
  final String attemptId;
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
  // A system save dialog can return a SAF content URI instead. It is kept
  // separate so no code ever passes `/document/...` to dart:io.
  final String? savedUri;
  // The object the partial bytes belong to. A resume sends the first of these
  // as If-Range, so a 206 can only continue the same file: without it a
  // re-encoded video at the same URL is spliced into the old one silently.
  final String? etag;
  final String? lastModified;

  DownloadQueueItem({
    String? attemptId,
    required this.fileName,
    required this.url,
    required this.isVideo,
    required this.receivedBytes,
    this.totalBytes,
    this.speedMbPerSec = 0,
    this.status = DownloadStatus.running,
    this.error,
    this.savedPath,
    this.savedUri,
    this.etag,
    this.lastModified,
  }) : attemptId = attemptId ?? const Uuid().v4();

  double get receivedMb => receivedBytes / 1048576;
  double? get totalMb => totalBytes == null ? null : totalBytes! / 1048576;

  /// What `If-Range` accepts: an entity tag first, the date only as a fallback.
  String? get validator => etag ?? lastModified;

  DownloadQueueItem copyWith({
    int? receivedBytes,
    int? totalBytes,
    double? speedMbPerSec,
    DownloadStatus? status,
    String? error,
    String? savedPath,
    String? savedUri,
    String? etag,
    String? lastModified,
    bool clearError = false,
  }) => DownloadQueueItem(
    attemptId: attemptId,
    fileName: fileName,
    url: url,
    isVideo: isVideo,
    receivedBytes: receivedBytes ?? this.receivedBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    speedMbPerSec: speedMbPerSec ?? this.speedMbPerSec,
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
    savedPath: savedPath ?? this.savedPath,
    savedUri: savedUri ?? this.savedUri,
    etag: etag ?? this.etag,
    lastModified: lastModified ?? this.lastModified,
  );

  Map<String, dynamic> toJson() => {
    'attemptId': attemptId,
    'fileName': fileName,
    'url': url,
    'isVideo': isVideo,
    'receivedBytes': receivedBytes,
    'totalBytes': totalBytes,
    'status': status.name,
    'error': error,
    'savedPath': savedPath,
    'savedUri': savedUri,
    'etag': etag,
    'lastModified': lastModified,
  };

  factory DownloadQueueItem.fromJson(Map<String, dynamic> json) {
    final rawPath = json['savedPath'] as String?;
    final rawUri = json['savedUri'] as String?;
    final uriFromOldPath = rawPath?.startsWith('content://') == true
        ? rawPath
        : null;
    return DownloadQueueItem(
      attemptId: (json['attemptId'] as String?)?.isNotEmpty == true
          ? json['attemptId'] as String
          : null,
      fileName: json['fileName'] as String? ?? '',
      url: json['url'] as String? ?? '',
      isVideo: json['isVideo'] as bool? ?? false,
      receivedBytes: json['receivedBytes'] as int? ?? 0,
      totalBytes: json['totalBytes'] as int?,
      status: DownloadStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => DownloadStatus.error,
      ),
      error: json['error'] as String?,
      savedPath:
          rawPath != null &&
              !rawPath.startsWith('content://') &&
              !rawPath.startsWith('/document/')
          ? rawPath
          : null,
      savedUri: rawUri?.startsWith('content://') == true
          ? rawUri
          : uriFromOldPath,
      etag: json['etag'] as String?,
      lastModified: json['lastModified'] as String?,
    );
  }
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
  Future<void>? _worker;
  bool _serviceUnavailable = false;
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
  final Map<String, String> _cancelledNames = {};

  // Hooks fired when a download lands at its destination: the Downloaded tab
  // re-scans the library folder through these.
  final Map<String, void Function()> _doneListeners = {};

  void addDoneListener(String key, void Function() listener) =>
      _doneListeners[key] = listener;

  void removeDoneListener(String key) => _doneListeners.remove(key);

  Future<File> _ledgerFile() async {
    final dir =
        debugDirectoryOverride ?? await getApplicationSupportDirectory();
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
      final items = <DownloadQueueItem>[];
      var needsSave = false;
      for (final raw in decoded) {
        try {
          if (raw is! Map<String, dynamic>) continue;
          final rawAttemptId = raw['attemptId'];
          final generated = rawAttemptId is! String || rawAttemptId.isEmpty;
          final rawSavedPath = raw['savedPath'];
          final migratedSavedLocation =
              rawSavedPath is String &&
              (rawSavedPath.startsWith('content://') ||
                  rawSavedPath.startsWith('/document/')) &&
              raw['savedUri'] == null;
          final item = DownloadQueueItem.fromJson(raw);
          if (item.fileName.isEmpty ||
              item.url.isEmpty ||
              items.any((existing) => existing.attemptId == item.attemptId)) {
            continue;
          }
          needsSave |= generated || migratedSavedLocation;
          items.add(
            item.status == DownloadStatus.running ||
                    item.status == DownloadStatus.queued
                ? item.copyWith(status: DownloadStatus.paused, speedMbPerSec: 0)
                : item,
          );
        } catch (_) {
          // One damaged row must not discard the rest of a valid queue.
        }
      }
      update(items, force: true);
      if (needsSave) await _save(force: true);
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
        await writeAtomically(
          file,
          jsonEncode(state.map((e) => e.toJson()).toList()),
        );
      } catch (e) {
        debugPrint('DownloadsModel save failed: $e');
      }
    } while (_dirty);
  }

  /// Waits for a forced save, including a write that was already in flight.
  Future<void> flush() async {
    while (true) {
      await _save(force: true);
      final inFlight = _writeInFlight;
      if (inFlight == null) return;
      await inFlight;
    }
  }

  @visibleForTesting
  Future<void> saveNow() => flush();

  bool get serviceUnavailable => _serviceUnavailable;

  void markServiceUnavailable() => _serviceUnavailable = true;

  void register(String fileName, String url, bool isVideo) {
    _serviceUnavailable = false;
    _cancelledNames.remove(fileName);
    final existing = List.of(state);
    existing.removeWhere((item) => item.fileName == fileName);
    // Appended: the list reads top-to-bottom exactly as transfers run, so
    // dragging an entry changes its execution order.
    final item = DownloadQueueItem(
      fileName: fileName,
      url: url,
      isVideo: isVideo,
      receivedBytes: 0,
      totalBytes: null,
      status: DownloadStatus.queued,
    );
    existing.add(item);
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
    var finished = items
        .where((item) => item.status == DownloadStatus.done)
        .length;
    if (finished <= _maxFinishedHistory) return;

    items.removeWhere((item) {
      if (item.status != DownloadStatus.done ||
          finished <= _maxFinishedHistory) {
        return false;
      }
      finished--;
      return true;
    });
  }

  bool contains(String fileName) =>
      state.any((item) => item.fileName == fileName);

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
    _cancelledNames.clear();
    _doneListeners.clear();
    _writeInFlight = null;
    _worker = null;
    _serviceUnavailable = false;
    _dirty = false;
    _lastSaveAt = 0;
    _loaded = false;
    update([], force: true);
  }

  int _indexOf(String fileName, {String? attemptId}) => state.indexWhere(
    (item) =>
        item.fileName == fileName &&
        (attemptId == null || item.attemptId == attemptId),
  );

  DownloadQueueItem? itemForAttempt(String attemptId) {
    final index = state.indexWhere((item) => item.attemptId == attemptId);
    return index < 0 ? null : state[index];
  }

  bool isAttemptCurrent(String fileName, String attemptId) =>
      _indexOf(fileName, attemptId: attemptId) >= 0;

  void attachCancel(
    String fileName,
    void Function() abort, {
    String? attemptId,
  }) {
    final index = _indexOf(fileName, attemptId: attemptId);
    if (index < 0) return;
    _cancelHooks[state[index].attemptId] = abort;
  }

  void progress(
    String fileName,
    int receivedBytes,
    int? totalBytes,
    double speedBytesPerSec, {
    String? attemptId,
  }) {
    final index = _indexOf(fileName, attemptId: attemptId);
    if (index < 0) return;
    final id = state[index].attemptId;
    if (_cancelled.contains(id) || _paused.contains(id)) return;

    final updated = [
      for (final item in state)
        item.attemptId == id
            ? item.copyWith(
                receivedBytes: receivedBytes,
                totalBytes: totalBytes,
                speedMbPerSec: speedBytesPerSec / 1048576,
              )
            : item,
    ];
    update(updated, force: true);
    DownloadsModel._pumpNotification(updated[index]);
    _save();
  }

  /// Records the bytes actually flushed to disk after the sink closed. Unlike
  /// [progress], it must run for a paused transfer: pause is exactly when the
  /// ledger and the file have to agree for the next Range request.
  void recordBytes(
    String fileName,
    int receivedBytes,
    int? totalBytes, {
    String? attemptId,
  }) {
    final index = _indexOf(fileName, attemptId: attemptId);
    if (index < 0 || _cancelled.contains(state[index].attemptId)) return;
    final id = state[index].attemptId;

    final updated = [
      for (final item in state)
        item.attemptId == id
            ? item.copyWith(
                receivedBytes: receivedBytes,
                totalBytes: totalBytes,
              )
            : item,
    ];
    update(updated, force: true);
    _save(force: true);
  }

  /// Remembers what the remote object is, so a resume can send `If-Range`.
  /// Written from the response headers of a full transfer.
  void setValidator(
    String fileName, {
    String? etag,
    String? lastModified,
    String? attemptId,
  }) {
    if ((etag == null || etag.isEmpty) &&
        (lastModified == null || lastModified.isEmpty)) {
      return;
    }
    final index = _indexOf(fileName, attemptId: attemptId);
    if (index < 0) return;
    final id = state[index].attemptId;

    final updated = [
      for (final item in state)
        item.attemptId == id
            ? item.copyWith(
                etag: etag == null || etag.isEmpty ? null : etag,
                lastModified: lastModified == null || lastModified.isEmpty
                    ? null
                    : lastModified,
              )
            : item,
    ];
    update(updated);
    _save();
  }

  /// Seed for a resumed download: the bytes already on disk in the temp file.
  int resumeOffsetFor(String fileName, {String? attemptId}) {
    for (final item in state) {
      if (item.fileName == fileName &&
          (attemptId == null || item.attemptId == attemptId) &&
          item.status == DownloadStatus.running) {
        return item.receivedBytes;
      }
    }
    return 0;
  }

  bool isCancelled(String fileName, {String? attemptId}) => attemptId != null
      ? _cancelled.contains(attemptId)
      : _cancelledNames.containsKey(fileName);

  bool isPaused(String fileName, {String? attemptId}) {
    final id = attemptId ?? itemFor(fileName)?.attemptId;
    return id != null && _paused.contains(id);
  }

  /// The worker has finished with this attempt. Flags belonging to a replaced
  /// attempt are deliberately left alone until that worker reports in.
  void clearTransient(String fileName, {String? attemptId}) {
    final id = attemptId ?? itemFor(fileName)?.attemptId;
    if (id == null) return;
    _cancelled.remove(id);
    _paused.remove(id);
    _cancelHooks.remove(id);
    if (_cancelledNames[fileName] == id) _cancelledNames.remove(fileName);
  }

  /// Runs the one queue worker and exposes a quiescence barrier to storage
  /// moves. A second kick waits for the active worker instead of starting a
  /// competing drain loop.
  Future<void> runWorker(Future<void> Function() task) async {
    final active = _worker;
    if (active != null) {
      await active;
      return;
    }
    final done = Completer<void>();
    _worker = done.future;
    try {
      await task();
    } finally {
      await saveNow();
      if (identical(_worker, done.future)) _worker = null;
      done.complete();
    }
  }

  Future<void> waitForWorkerIdle() async {
    while (true) {
      final active = _worker;
      if (active == null) break;
      await active;
    }
    await saveNow();
  }

  /// Holds the whole queue: the running transfer is paused in place and the
  /// waiting ones move to paused too, so Resume-all can bring every entry back
  /// in order (each resuming from its partial bytes).
  Future<void> pauseAll() async {
    final active = state
        .where(
          (item) =>
              item.status == DownloadStatus.running ||
              item.status == DownloadStatus.queued,
        )
        .toList();
    for (final item in active) {
      pause(item.fileName, attemptId: item.attemptId);
    }
    await waitForWorkerIdle();
  }

  /// Holds a running download: the transfer aborts, but the entry and its
  /// partial bytes stay, so [requeue]-ing it later resumes with a Range request.
  ///
  /// [_paused] is set *before* the abort hook runs, because the hook is only
  /// attached once [_downloadToTemp] has done its first awaits (a temporary
  /// directory, the cache lookup). Pausing in that window used to find no hook,
  /// so nothing aborted the socket: the entry showed "paused" and stopped
  /// updating while bytes kept flowing until the next pause or cancel.
  Future<void> pause(String fileName, {String? attemptId}) {
    final index = _indexOf(fileName, attemptId: attemptId);
    if (index < 0) return Future<void>.value();
    final id = state[index].attemptId;

    _paused.add(id);
    _cancelHooks.remove(id)?.call();

    final updated = [
      for (final item in state)
        item.attemptId == id
            ? item.copyWith(status: DownloadStatus.paused, speedMbPerSec: 0)
            : item,
    ];
    update(updated, force: true);
    DownloadsModel._pumpNotification(updated[index]);
    return _save(force: true);
  }

  /// Hands the next turn to a waiting entry: it becomes the one running
  /// download (its partial bytes are kept for a resume). False when the entry
  /// was removed while it waited, so the worker can stop before writing.
  Future<bool> startRunning(String fileName, {String? attemptId}) async {
    final index = _indexOf(fileName, attemptId: attemptId);
    if (index < 0) return false;
    final id = state[index].attemptId;
    if (state[index].status == DownloadStatus.paused) return false;
    _cancelled.remove(id);
    _paused.remove(id);

    final updated = [
      for (final item in state)
        item.attemptId == id
            ? item.copyWith(
                status: DownloadStatus.running,
                speedMbPerSec: 0,
                clearError: true,
              )
            : item,
    ];
    update(updated, force: true);
    try {
      await _pumpStart(updated[index]);
    } catch (_) {
      _serviceUnavailable = true;
      await pause(fileName, attemptId: id);
      await DownloadNotifications.clear();
      await saveNow();
      return false;
    }
    _save(force: true);
    return true;
  }

  /// Puts a failed or paused entry back at the waiting line (a retry/resume
  /// goes through the same one-at-a-time queue).
  void requeue(String fileName, {String? attemptId}) {
    final index = _indexOf(fileName, attemptId: attemptId);
    if (index < 0) return;
    _serviceUnavailable = false;
    final id = state[index].attemptId;
    _cancelled.remove(id);
    _paused.remove(id);

    final updated = [
      for (final item in state)
        item.attemptId == id
            ? item.copyWith(
                status: DownloadStatus.queued,
                speedMbPerSec: 0,
                clearError: true,
              )
            : item,
    ];
    update(updated, force: true);
    _save(force: true);
  }

  /// Rewrites the paths of finished entries after the library moved. The
  /// stored path is what the done card opens; leaving it on the old root made
  /// every finished row point at a file that is no longer there.
  Future<void> relocateSavedPaths(
    String oldRoot,
    String newRoot, {
    Map<String, String> relocatedPaths = const {},
  }) async {
    if (oldRoot.isEmpty || newRoot.isEmpty || p.equals(oldRoot, newRoot)) {
      return;
    }

    var changed = false;
    final normalizedRelocations = {
      for (final entry in relocatedPaths.entries)
        p.normalize(entry.key): p.normalize(entry.value),
    };
    final hasRelocationMap = normalizedRelocations.isNotEmpty;
    final updated = <DownloadQueueItem>[];
    for (final item in state) {
      final saved = item.savedPath;
      if (saved != null && p.isWithin(oldRoot, saved)) {
        final normalizedSaved = p.normalize(saved);
        final moved =
            normalizedRelocations[normalizedSaved] ??
            (hasRelocationMap
                ? null
                : p.join(newRoot, p.relative(saved, from: oldRoot)));
        if (moved != null && File(moved).existsSync()) {
          updated.add(item.copyWith(savedPath: moved));
          changed = true;
          continue;
        }
      }
      updated.add(item);
    }
    if (!changed) return;
    update(updated);
    await _save(force: true);
  }

  void markDone(
    String fileName, {
    String? savedPath,
    String? savedUri,
    String? attemptId,
  }) {
    final index = _indexOf(fileName, attemptId: attemptId);
    if (index < 0) return;
    final id = state[index].attemptId;
    _cancelHooks.remove(id);
    _paused.remove(id);

    final updated = [
      for (final item in state)
        item.attemptId == id
            ? item.copyWith(
                status: DownloadStatus.done,
                clearError: true,
                savedPath: savedPath,
                savedUri: savedUri,
              )
            : item,
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
  void fail(String fileName, {String? error, String? attemptId}) {
    final index = _indexOf(fileName, attemptId: attemptId);
    if (index < 0) return;
    final id = state[index].attemptId;
    _cancelHooks.remove(id);
    _paused.remove(id);

    final updated = [
      for (final item in state)
        item.attemptId == id
            ? item.copyWith(status: DownloadStatus.error, error: error)
            : item,
    ];
    update(updated, force: true);
    DownloadsModel._pumpNotification(updated[index]);
    _save(force: true);
  }

  /// User-initiated abort from the queue screen: the entry and its partial
  /// bytes go away entirely.
  void cancel(String fileName, {String? attemptId}) {
    final index = _indexOf(fileName, attemptId: attemptId);
    if (index < 0) return;
    final id = state[index].attemptId;
    _cancelled.add(id);
    _cancelledNames[fileName] = id;
    _paused.remove(id);
    _cancelHooks.remove(id)?.call();
    unawaited(deletePartial(fileName, attemptId: id));
    final updated = state.where((item) => item.attemptId != id).toList();
    update(updated, force: true);
    DownloadsModel._clearIfIdle(updated);
    _save(force: true);
  }

  void remove(String fileName, {String? attemptId}) {
    final item = attemptId == null
        ? itemFor(fileName)
        : itemForAttempt(attemptId);
    if (item == null || item.fileName != fileName) return;
    // A running transfer must be aborted before its partial file is unlinked;
    // otherwise the worker keeps writing to an unlinked path.
    if (item.status == DownloadStatus.running) {
      cancel(fileName, attemptId: item.attemptId);
      return;
    }
    unawaited(deletePartial(fileName, attemptId: item.attemptId));
    final updated = state
        .where((entry) => entry.attemptId != item.attemptId)
        .toList();
    update(updated, force: true);
    DownloadsModel._clearIfIdle(updated);
    _save(force: true);
  }

  void clearFinished() {
    final updated = state
        .where((item) => item.status != DownloadStatus.done)
        .toList();
    update(updated, force: true);
    _save(force: true);
  }

  /// The worker has drained the queue: with nothing running or waiting the
  /// foreground service has no reason to stay up. Called from the worker's own
  /// finally, so the service survives every retry pause.
  Future<void> notifyWorkerIdle() async {
    await saveNow();
    if (state.any((item) => item.status == DownloadStatus.running)) return;
    await DownloadNotifications.clear();
  }

  static void _pumpNotification(DownloadQueueItem item) =>
      DownloadNotifications.update(item);

  static Future<void> _pumpStart(DownloadQueueItem item) =>
      DownloadNotifications.start(item);

  static void _pumpFinalize(DownloadQueueItem item) =>
      DownloadNotifications.finalize(item);

  static void _clearIfIdle(List<DownloadQueueItem> items) {
    final busy = items.any(
      (item) =>
          item.status == DownloadStatus.running ||
          item.status == DownloadStatus.queued,
    );
    if (!busy) DownloadNotifications.clear();
  }
}
