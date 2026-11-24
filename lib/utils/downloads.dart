import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'package:quax/constants.dart';
import 'package:quax/downloads/download_paths.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/downloads/saved_media.dart';
import 'package:quax/downloads/video_cache.dart';
import 'package:quax/downloads/atomic_copy.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/library/library_model.dart';
import 'package:quax/tweet/video_metadata.dart';
import 'package:quax/ui/errors.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pref/pref.dart';
import 'package:share_plus/share_plus.dart';

const _storageChannel = quaxMethodChannel;

/// The single download worker: it pulls the first waiting entry (top of the
/// queue list = next to run, so dragging the queue reorders transfers), works
/// through it, then picks the next. The old FIFO chain is gone — a plain chain
/// could not honor pause, stop-all or reordering.
///
/// [_workerPrefs] is a module global rather than a parameter because the worker
/// outlives the call that started it, and a resume arrives from the connectivity
/// watcher, which has no BuildContext of its own. It is only ever null before
/// the first enqueue, which [_kickWorker] treats as "nothing to do".
BasePrefService? _workerPrefs;
final Map<String, BuildContext?> _workerContexts = {};

void _kickWorker() {
  final queue = DownloadsModel();
  _workerContexts.removeWhere(
    (attemptId, _) => queue.itemForAttempt(attemptId) == null,
  );
  _retryAfter.removeWhere(
    (attemptId, _) => queue.itemForAttempt(attemptId) == null,
  );
  if (_workerPrefs == null || queue.serviceUnavailable) return;
  unawaited(
    queue.runWorker(_drainQueue).whenComplete(() {
      _workerContexts.removeWhere(
        (attemptId, _) => queue.itemForAttempt(attemptId) == null,
      );
      if (queue.nextQueued != null && !queue.serviceUnavailable) _kickWorker();
    }),
  );
}

Future<void> _drainQueue() async {
  final prefs = _workerPrefs;
  if (prefs == null) return;

  final queue = DownloadsModel();
  try {
    while (true) {
      final next = queue.nextQueued;
      if (next == null) return;

      final context = _workerContexts.remove(next.attemptId);
      await _runDownload(
        context,
        Uri.parse(next.url),
        next.fileName,
        prefs: prefs,
        resume: true,
        attemptId: next.attemptId,
      );
      queue.clearTransient(next.fileName, attemptId: next.attemptId);
      if (queue.itemForAttempt(next.attemptId)?.status ==
          DownloadStatus.paused) {
        return;
      }
    }
  } finally {
    await queue.notifyWorkerIdle();
  }
}

/// A transfer that receives nothing for this long is considered stalled: the
/// connection is dropped and the entry becomes retryable (resuming where it
/// stopped), instead of hanging on a dead socket forever.
const _idleTimeout = Duration(seconds: 30);

/// A CDN edge that never answers would otherwise pin the single queue worker
/// until the OS gives up, because [http.Client.send] has no timeout of its own.
const _responseTimeout = Duration(seconds: 20);

/// Attempts per transfer: the first one plus transient-failure retries.
const _maxAttempts = 3;

/// The longest pause the app will take on its own. A server asking for more
/// than this is telling the reader to come back later, not to retry sooner.
const _maxRetryDelay = Duration(minutes: 2);

final _random = Random();

/// What the last failed response asked us to wait, per attempt. A 503 with
/// `Retry-After` must not be retried at the app's own pace.
final Map<String, Duration> _retryAfter = {};

/// Delay before the next attempt: exponential, jittered, and never shorter
/// than what the server asked for. The jitter matters because several entries
/// that failed together would otherwise come back in lockstep.
@visibleForTesting
Duration retryDelayFor(int attempt, {Duration? requested}) {
  final exponential = Duration(seconds: 2 << attempt);
  final jitter = Duration(milliseconds: _random.nextInt(1000));
  final delay = exponential + jitter;
  final withRequest = requested != null && requested > delay
      ? requested
      : delay;
  return withRequest > _maxRetryDelay ? _maxRetryDelay : withRequest;
}

/// `Retry-After` as seconds. The HTTP-date form is rare from a CDN and would
/// cost a parser; an unparseable header simply falls back to the backoff.
@visibleForTesting
Duration? parseRetryAfter(String? value) {
  if (value == null) return null;
  final seconds = int.tryParse(value.trim());
  if (seconds == null) return null;
  return Duration(seconds: seconds.clamp(1, 300));
}

/// Whether the failed attempt should throw its partial file away.
///
/// A server that answers 503 to a Range request has told us the request shape
/// is the problem, not the bytes: retrying with the same Range converges on
/// the same answer. The second server error therefore restarts from zero.
@visibleForTesting
bool shouldRestartFromZero(int attempt, String? error) =>
    attempt >= 1 && (error?.startsWith('HTTP 5') ?? false);

/// Never start a transfer that cannot fit in the destination (+ headroom).
const _spaceMarginBytes = 64 * 1024 * 1024;

/// Auto-caching short videos runs on its own chain, behind the manual queue,
/// so a prefetch never delays a download the user actually asked for.
Future<void> _cacheChain = Future.value();

/// Cache jobs allowed to wait behind the manual queue. A fling through a
/// video-heavy feed used to append one closure per video it passed, with no
/// way to drop the ones already off screen; the queue then worked through
/// clips nobody was looking at before the reader's own download started.
const _maxQueuedCacheJobs = 3;
int _queuedCacheJobs = 0;

void _enqueueCache(Future<void> Function() task) {
  if (_queuedCacheJobs >= _maxQueuedCacheJobs) return;
  _queuedCacheJobs++;
  _cacheChain = _cacheChain
      .then((_) => task())
      .catchError((_) {})
      .whenComplete(() => _queuedCacheJobs--);
}

/// Keeps a short video for later: fetches it into [VideoCache] in the
/// background, one clip at a time. Used when a video scrolls into view and the
/// matching setting is on; quietly gives up on anything (metered connection,
/// already cached or downloaded, failures) so the feed is never disturbed.
Future<void> cacheVideoAhead({
  required Future<TweetVideoUrls> Function() urls,
  required BasePrefService prefs,
}) async {
  if (!(prefs.get<bool>(optionAutoCacheVideos) ?? false)) return;
  // Manual media loading means the user is watching their data deliberately.
  if (prefs.get<bool>(optionMediaDisableAutoload) ?? false) return;

  _enqueueCache(() async {
    try {
      if (prefs.get<bool>(optionAutoCacheWifiOnly) ?? true) {
        final metered = await isMeteredConnection();
        if (metered == true) return;
      }

      final resolved = await urls();
      final target = resolved.downloadUrl ?? resolved.streamUrl;
      if (target.isEmpty) return;

      final cache = VideoCache();
      if (await cache.localPathFor(target) != null) return;
      if (await LibraryModel(prefs).localPathFor(target) != null) return;

      final name = VideoCache.fileNameFor(target);
      // Not queue-managed: this name is never a queue row, so a cancel hook
      // would leak for the process lifetime and the resumable temp name would
      // be reused by an unrelated later attempt.
      final temp = await _downloadToTemp(
        null,
        Uri.parse(target),
        'cache-$name',
        targetDir: (await cache.directory()).path,
        queueManaged: false,
      );
      if (temp == null) return;

      await cache.put(target, File(temp), prefs: prefs);
    } catch (_) {
      // Auto-caching is best-effort.
    }
  });
}

/// Whether the phone is on a metered connection (cellular, hotspot); null when
/// Android cannot tell. Shared by every feature that fetches ahead of time.
Future<bool?> isMeteredConnection() async {
  try {
    return await _storageChannel.invokeMethod<bool>('isMetered');
  } on Exception {
    return null;
  }
}

String _sanitized(String fileName) {
  // X media URLs carry a size suffix (`photo.jpg:orig`). Left in, the saved
  // file's extension becomes `.jpg:orig` and the library scan skips it.
  final name = p
      .basename(fileName.split('?').first)
      .replaceFirst(RegExp(r':(orig|large|medium|small|thumb)$'), '');
  if (name.isEmpty || name.length > 180) {
    // Android rejects names this long in the media scanner.
    return 'media-${DateTime.now().millisecondsSinceEpoch}';
  }
  return name;
}

bool _isVideo(String fileName) => fileName.contains(
  RegExp(
    r'\.(mp4|mov|webm|mkv|m4v|avi|ts|3gp|mpeg|mpg|wmv|flv|m2ts|ogv)$',
    caseSensitive: false,
  ),
);

/// Queues [uri] into the one-at-a-time download queue and, when its turn comes,
/// saves the file into the hidden library (or through the system dialog before
/// the library exists) and offers a share sheet. A transfer that is already
/// active for the same file is left alone instead of being re-queued twice.
Future<void> downloadUriToPickedFile(
  BuildContext context,
  Uri uri,
  String fileName, {
  required BasePrefService prefs,
}) async {
  final name = _sanitized(fileName);
  final queue = DownloadsModel();
  if (queue.isActive(name)) return;

  queue.register(name, uri.toString(), _isVideo(name));
  _workerPrefs = prefs;
  _workerContexts[queue.itemFor(name)!.attemptId] = context;
  _kickWorker();
}

/// The actual transfer, run when the entry reaches the head of the queue.
/// Transient failures (stalls, dropped sockets, incomplete streams, 5xx) are
/// retried up to [_maxAttempts] with a growing pause, resuming from the bytes
/// already on disk. A null [context] means nobody is watching (an automatic
/// resume): unchanged progress and errors just stay in the queue.
Future<void> _runDownload(
  BuildContext? context,
  Uri uri,
  String fileName, {
  required BasePrefService prefs,
  bool resume = false,
  String? attemptId,
}) async {
  final queue = DownloadsModel();
  final id = attemptId ?? queue.itemFor(fileName)?.attemptId;
  if (id == null ||
      !queue.isAttemptCurrent(fileName, id) ||
      queue.isCancelled(fileName, attemptId: id)) {
    return;
  }
  bool current() => queue.isAttemptCurrent(fileName, id);
  bool held() =>
      queue.isCancelled(fileName, attemptId: id) ||
      queue.isPaused(fileName, attemptId: id);

  try {
    // Capture one destination root for the whole attempt. A storage move pauses
    // and drains the worker before changing this preference.
    final configuredRoot = prefs.get<String>(optionLibraryPath);
    final libraryRoot = configuredRoot != null && configuredRoot.isNotEmpty
        ? configuredRoot
        : null;
    final targetDir = libraryRoot ?? (await getTemporaryDirectory()).path;
    if (!current() || held()) return;
    if (!await queue.startRunning(fileName, attemptId: id)) return;

    // An auto-cached copy makes both play and download instant: nothing to
    // fetch, the queue item just promotes the file into the library.
    final cache = VideoCache();
    final cachedPath = await cache.localPathFor(uri.toString());

    String? tempPath = cachedPath;
    if (cachedPath == null) {
      for (var attempt = 0; attempt < _maxAttempts; attempt++) {
        if (attempt > 0 && !await queue.startRunning(fileName, attemptId: id)) {
          return;
        }

        // _downloadToTemp only hands the context to _showStatusError, which
        // checks it itself; a transfer must not stop because the screen that
        // started it went away.
        tempPath = await _downloadToTemp(
          // ignore: use_build_context_synchronously
          context,
          uri,
          fileName,
          attemptId: id,
          resume: resume || attempt > 0,
          targetDir: targetDir,
          destinationIsSaf: libraryRoot == null,
        );
        if (tempPath != null) {
          _retryAfter.remove(id);
          break;
        }

        final item = queue.itemForAttempt(id);
        final error = item?.error;
        if (item == null || held() || !_isRetryable(error)) {
          _retryAfter.remove(id);
          return;
        }

        if (shouldRestartFromZero(attempt, error)) {
          await deletePartial(fileName, attemptId: id);
        }

        final requested = _retryAfter.remove(id);
        if (attempt == _maxAttempts - 1) return;
        if (!await _waitForRetry(
          id,
          retryDelayFor(attempt, requested: requested),
        )) {
          return;
        }
      }
    }
    if (tempPath == null) return;
    // Re-check immediately before promotion: pause/cancel can arrive while a
    // cached file is inspected or the response stream is closing.
    if (!current() || held()) {
      if (!current()) await _deleteTemp(tempPath);
      return;
    }

    var promoted = false;
    var keepTemp = true;
    try {
      final saved = await _saveToDestination(
        // ignore: use_build_context_synchronously
        context,
        file: tempPath,
        fileName: fileName,
        libraryRoot: libraryRoot,
        attemptId: id,
        prefs: prefs,
      );
      if (saved.location.path != null || saved.location.isUri) {
        keepTemp = false;
        final path = saved.location.path;
        if (path != null) {
          await LibraryModel(prefs).registerLocalMedia(uri.toString(), path);
        }
        queue.markDone(
          fileName,
          savedPath: path,
          savedUri: saved.location.uri,
          attemptId: id,
        );
        await queue.flush();
        // ignore: use_build_context_synchronously
        _showSuccess(context, saved.location);
        if (cachedPath != null) {
          promoted = true;
          await cache.remove(uri.toString());
        }
      } else if (saved.cancelled) {
        keepTemp = false;
        queue.remove(fileName, attemptId: id);
      } else {
        queue.fail(fileName, error: 'save_unavailable', attemptId: id);
      }
    } finally {
      if ((cachedPath == null || promoted) && !keepTemp) {
        await _deleteTemp(tempPath);
      }
    }
  } catch (e) {
    if (!current() || held()) return;
    queue.fail(fileName, error: _downloadError(e), attemptId: id);
    if (context != null && context.mounted) {
      showSnackBar(context, icon: '🙊', message: e.toString());
    }
  }
}

Future<bool> _waitForRetry(String attemptId, Duration delay) async {
  final queue = DownloadsModel();
  final until = DateTime.now().add(delay);
  while (DateTime.now().isBefore(until)) {
    final item = queue.itemForAttempt(attemptId);
    if (item == null ||
        queue.isCancelled(item.fileName, attemptId: attemptId) ||
        queue.isPaused(item.fileName, attemptId: attemptId)) {
      return false;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return queue.itemForAttempt(attemptId) != null &&
      !queue.isPaused(
        queue.itemForAttempt(attemptId)!.fileName,
        attemptId: attemptId,
      );
}

/// True when an automatic retry can plausibly succeed. 4xx (except 408), a
/// full disk and stale interrupted markers are left to the manual Retry.
bool isRetryableDownloadError(String? error) => _isRetryable(error);

/// The most bytes a partial file may run ahead of the ledger and still be
/// trusted. The ledger is flushed at most every 1.5 s, so a fast link can
/// write a few MB between the last sample and the process dying; anything
/// larger means the two files are not the pair we think they are.
const _maxLedgerLagBytes = 8 * 1024 * 1024;

/// The byte offset a resume may ask for.
///
/// A partial file that matches the ledger exactly is the clean case. A file
/// that is *ahead* of it is the after-a-crash case: the process died between a
/// socket write and the ledger flush, so the bytes on disk are still a prefix
/// of the remote object and the recorded byte is a valid resume point once the
/// extra ones are dropped. Treating that as a mismatch used to restart every
/// killed transfer from zero, which is the one case resume exists for.
int resumeOffset({
  required bool resume,
  required int recordedBytes,
  required bool fileExists,
  required int fileLength,
}) {
  if (!resume || recordedBytes <= 0 || !fileExists) return 0;
  if (fileLength == recordedBytes) return recordedBytes;
  if (fileLength > recordedBytes &&
      fileLength - recordedBytes <= _maxLedgerLagBytes) {
    return recordedBytes;
  }
  return 0;
}

/// Re-queues a failed entry without any UI: the connectivity watcher uses it
/// when the network comes back.
void resumeDownload(DownloadQueueItem item, {required BasePrefService prefs}) {
  DownloadsModel().requeue(item.fileName, attemptId: item.attemptId);
  _workerPrefs = prefs;
  _kickWorker();
}

/// Server-side/client-side errors worth another automatic try. 4xx (except
/// 408) and a full disk never succeed on retry.
bool _isRetryable(String? error) {
  if (error == null || error.isEmpty) return false;
  if (error.startsWith('HTTP') &&
      !error.startsWith('HTTP 408') &&
      !error.startsWith('HTTP 5')) {
    return false;
  }
  if (error == 'no_space' ||
      error == 'interrupted' ||
      error == 'save_unavailable') {
    return false;
  }
  return true;
}

String _downloadError(Object e) {
  if (e is TimeoutException) return 'timeout';
  // ENOSPC: a full disk looks like a transient socket failure in the catch
  // above, and the retry loop would download the same bytes three more times.
  if (e is FileSystemException && e.osError?.errorCode == 28) return 'no_space';
  return e.toString();
}

Future<bool> _sameStorageVolume(String first, String second) async {
  if (p.equals(first, second)) return true;
  try {
    return await _storageChannel.invokeMethod<bool>('isSameStorageVolume', {
          'path1': first,
          'path2': second,
        }) ??
        false;
  } on Exception {
    // Older/native-unavailable builds conservatively assume a copy is needed.
    return false;
  }
}

Future<int?> _availableSpace(String path) async {
  try {
    return await _storageChannel.invokeMethod<int>('getAvailableSpace', {
      'path': path,
    });
  } on Exception {
    return null;
  }
}

Future<void> _deleteTemp(String? tempPath) async {
  try {
    if (tempPath != null && await File(tempPath).exists()) {
      await File(tempPath).delete();
    }
  } catch (_) {}
}

void _showSuccess(BuildContext? context, SavedMediaLocation saved) {
  if (context == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('✅ ${L10n.of(context).successfully_saved_the_media}'),
      action: SnackBarAction(
        label: L10n.of(context).share,
        onPressed: () async {
          final file = await shareableFileForSavedMedia(saved);
          if (file == null) return;
          try {
            await SharePlus.instance.share(
              ShareParams(files: [XFile(file.path)]),
            );
          } finally {
            if (saved.isUri) await _deleteTemp(file.path);
          }
        },
      ),
    ),
  );
}

/// Downloads [uri] right away (no queue: a share is a foreground action) and
/// opens the share sheet with the file — the "send the meme straight to
/// WhatsApp" shortcut.
Future<void> downloadAndShare(
  BuildContext context,
  Uri uri,
  String fileName,
) async {
  final sanitizedFilename = _sanitized(fileName);

  String? tempPath;
  try {
    final targetDir = (await getTemporaryDirectory()).path;
    // _downloadToTemp tolerates a context whose screen is gone; only the error
    // snackbar is skipped.
    tempPath = await _downloadToTemp(
      // ignore: use_build_context_synchronously
      context,
      uri,
      sanitizedFilename,
      targetDir: targetDir,
      queueManaged: false,
    );
    if (tempPath == null) return;

    if (context.mounted) {
      await SharePlus.instance.share(ShareParams(files: [XFile(tempPath)]));
    }
  } catch (e) {
    if (context.mounted) {
      showSnackBar(context, icon: '🙊', message: e.toString());
    }
  } finally {
    _deleteTemp(tempPath);
  }
}

void _showStatusError(BuildContext? context, Object statusCode) {
  if (context == null || !context.mounted) return;
  showSnackBar(
    context,
    icon: '🙊',
    message: L10n.of(context)
        .unable_to_save_the_media_twitter_returned_a_status_of_response_statusCode(
          statusCode,
        ),
  );
}

/// Saves the downloaded temp file to the user's destination. `cancelled` is
/// true only when the reader dismissed the system dialog; a missing library
/// with nobody watching returns neither path nor cancellation, so the caller
/// can fail the entry instead of deleting it. The hidden library is the normal
/// destination; without a configured folder the system save dialog keeps
/// downloads usable. An existing file with the same name is never overwritten:
/// the new copy gets a timestamp suffix.
Future<({SavedMediaLocation location, bool cancelled})> _saveToDestination(
  BuildContext? context, {
  required String file,
  required String fileName,
  required String? libraryRoot,
  required String attemptId,
  required BasePrefService prefs,
}) async {
  final queue = DownloadsModel();
  final item = queue.itemForAttempt(attemptId);
  if (item == null ||
      queue.isCancelled(item.fileName, attemptId: attemptId) ||
      queue.isPaused(item.fileName, attemptId: attemptId)) {
    return (location: const SavedMediaLocation(), cancelled: false);
  }

  if (libraryRoot != null && libraryRoot.isNotEmpty) {
    final library = Directory(libraryRoot);
    if (await library.exists()) {
      var savedFile = p.join(library.path, fileName);
      if (await File(savedFile).exists()) {
        savedFile = p.join(
          library.path,
          '${p.basenameWithoutExtension(fileName)}-${DateTime.now().millisecondsSinceEpoch}'
          '${p.extension(fileName)}',
        );
      }
      final source = File(file);
      await moveFileAtomically(
        source,
        File(savedFile),
        shouldCommit: () async {
          final current = queue.itemForAttempt(attemptId);
          return current != null &&
              !queue.isCancelled(item.fileName, attemptId: attemptId) &&
              !queue.isPaused(item.fileName, attemptId: attemptId);
        },
      );
      if (!LibraryModel(prefs).isHidden) {
        try {
          await _storageChannel.invokeMethod('scanMediaFile', {
            'path': savedFile,
          });
        } catch (_) {
          // The file is saved even when MediaStore is unavailable.
        }
      }
      return (location: SavedMediaLocation(path: savedFile), cancelled: false);
    }
  }

  // The system dialog needs a live screen; an automatic resume has none.
  // ignore: use_build_context_synchronously
  if (context == null || !context.mounted) {
    return (location: const SavedMediaLocation(), cancelled: false);
  }

  final saved = await _storageChannel.invokeMethod<String>('saveMediaFile', {
    'sourcePath': file,
    'fileName': fileName,
  });
  final location = SavedMediaLocation.parse(saved);
  return (location: location, cancelled: saved == null);
}

/// Queues the retry of a failed entry through the same one-at-a-time queue
/// (first in line when the current transfer ends). When the server honours
/// Range requests the download resumes from the bytes already on disk.
Future<void> retryDownload(
  BuildContext context,
  DownloadQueueItem item, {
  required BasePrefService prefs,
}) async {
  DownloadsModel().requeue(item.fileName, attemptId: item.attemptId);

  _workerPrefs = prefs;
  _workerContexts[item.attemptId] = context;
  _kickWorker();
}

http.Request _rangeRequest(Uri uri, int offset, {String? validator}) {
  final request = http.Request('GET', uri);
  if (offset > 0) {
    request.headers['range'] = 'bytes=$offset-';
    // If-Range turns a changed object into a 200 (start over) instead of a 206
    // that would be appended to bytes from a different encode.
    if (validator != null) request.headers['if-range'] = validator;
  }
  return request;
}

/// `send()` waits for the connection, TLS and the first response byte with no
/// timeout of its own. A dead socket therefore used to pin the only queue
/// worker until the OS gave up.
Future<http.StreamedResponse> _send(
  http.Client client,
  Uri uri,
  int offset, {
  String? validator,
}) => client
    .send(_rangeRequest(uri, offset, validator: validator))
    .timeout(_responseTimeout);

class ContentRange {
  const ContentRange(this.start, this.end, this.total);

  final int start;
  final int end;
  final int total;
  int get length => end - start + 1;
}

/// Validates the whole 206 contract, not just the first number. A short or
/// malformed range is rejected rather than appended and later reported as a
/// complete file.
@visibleForTesting
ContentRange? parseContentRange(
  String? value, {
  required int? bodyLength,
  bool requireCompleteRemainder = false,
}) {
  if (value == null || bodyLength == null) return null;
  final match = RegExp(
    r'^bytes\s+(\d+)-(\d+)/(\d+)$',
    caseSensitive: false,
  ).firstMatch(value.trim());
  if (match == null) return null;
  final start = int.tryParse(match.group(1)!);
  final end = int.tryParse(match.group(2)!);
  final total = int.tryParse(match.group(3)!);
  if (start == null || end == null || total == null || total <= 0) return null;
  if (start < 0 || end < start || end >= total) return null;
  if (end - start + 1 != bodyLength) return null;
  if (requireCompleteRemainder && end != total - 1) return null;
  return ContentRange(start, end, total);
}

/// Test seam for the transfer path: production callers always go through the
/// queue worker, and the HTTP client is injectable so a fake server can answer
/// 200/206/416 without a socket.
@visibleForTesting
Future<String?> debugDownloadToTemp(
  Uri uri,
  String fileName, {
  bool resume = false,
  required String targetDir,
  bool queueManaged = true,
  http.Client? client,
  bool destinationIsSaf = false,
}) => _downloadToTemp(
  null,
  uri,
  fileName,
  resume: resume,
  targetDir: targetDir,
  queueManaged: queueManaged,
  client: client,
  destinationIsSaf: destinationIsSaf,
);

/// Streams the response to a temporary file while feeding the downloads queue
/// (visible on the Downloads navbar tab) — Hentoid-style: the reader stays
/// usable while files download in the background. Cancels through the queue.
/// Failed downloads keep their partial file so a retry can resume.
/// Returns the temp path, or null when the download failed or was cancelled.
/// The actual bytes over the wire. A null [context] — or one whose screen is
/// gone — means nobody is watching: the transfer still runs to completion and
/// only the error snackbar is skipped, which is why the call sites hand it a
/// context that may already be dead.
Future<String?> _downloadToTemp(
  BuildContext? context,
  Uri uri,
  String fileName, {
  bool resume = false,
  required String targetDir,
  bool queueManaged = true,
  http.Client? client,
  String? attemptId,
  bool destinationIsSaf = false,
}) async {
  final queue = DownloadsModel();
  final id = queueManaged
      ? (attemptId ?? queue.itemFor(fileName)?.attemptId)
      : null;
  if (queueManaged && id == null) return null;
  final item = id == null ? null : queue.itemForAttempt(id);
  var tempPath = queueManaged
      ? await partialPathFor(fileName, attemptId: id)
      : await shareTempPathFor(fileName);
  if (queueManaged && resume && id != null && !await File(tempPath).exists()) {
    final legacy = File(await legacyPartialPathFor(fileName));
    if (await legacy.exists()) {
      await moveFileAtomically(legacy, File(tempPath));
    }
  }
  final httpClient = client ?? http.Client();
  var keepTemp = false;

  if (queueManaged && id != null) {
    queue.attachCancel(fileName, () {
      httpClient.close(); // the stream loop surfaces as a ClientException and cleans up
    }, attemptId: id);
  }

  try {
    // Resume only when the partial file still matches the recorded offset.
    final partial = File(tempPath);
    final partialExists = await partial.exists();
    final partialLength = partialExists ? await partial.length() : 0;

    // A save that failed after a complete transfer leaves the whole file in
    // the temp path. Do not download it again just to retry the copy.
    if (resume &&
        item != null &&
        item.totalBytes != null &&
        item.receivedBytes >= item.totalBytes! &&
        partialExists &&
        partialLength == item.receivedBytes) {
      keepTemp = true;
      return tempPath;
    }

    var offset = resumeOffset(
      resume: resume && queueManaged,
      recordedBytes: queueManaged
          ? queue.resumeOffsetFor(fileName, attemptId: id)
          : 0,
      fileExists: partialExists,
      fileLength: partialLength,
    );
    // A killed transfer leaves the file ahead of the ledger. Drop the extra
    // bytes so the append starts exactly where the ledger says it does.
    if (offset > 0 && partialLength > offset) {
      final raf = await partial.open(mode: FileMode.append);
      try {
        await raf.truncate(offset);
      } finally {
        await raf.close();
      }
    }

    final validator = item?.validator;
    if (queueManaged &&
        (queue.isCancelled(fileName, attemptId: id) ||
            queue.isPaused(fileName, attemptId: id))) {
      return null;
    }
    var response = await _send(httpClient, uri, offset, validator: validator);
    if (response.statusCode == 416 && offset > 0) {
      // The partial bytes no longer match the remote file: start over clean.
      await _deleteTemp(tempPath);
      offset = 0;
      response = await _send(httpClient, uri, 0);
    }

    ContentRange? partialRange;
    var isPartial = response.statusCode == 206;
    if (isPartial) {
      partialRange = parseContentRange(
        response.headers['content-range'],
        bodyLength: response.contentLength,
        requireCompleteRemainder: true,
      );
      if (partialRange == null || (offset == 0 && partialRange.start != 0)) {
        if (queueManaged) {
          queue.fail(fileName, error: 'invalid_range', attemptId: id);
        }
        return null;
      }
      // A proxy that answers a complete range from zero is stale, not corrupt:
      // discard the partial and re-request the whole object once.
      if (offset > 0 && partialRange.start != offset) {
        await _deleteTemp(tempPath);
        offset = 0;
        response = await _send(httpClient, uri, 0);
        isPartial = response.statusCode == 206;
        partialRange = isPartial
            ? parseContentRange(
                response.headers['content-range'],
                bodyLength: response.contentLength,
                requireCompleteRemainder: true,
              )
            : null;
        if (isPartial && (partialRange == null || partialRange.start != 0)) {
          if (queueManaged) {
            queue.fail(fileName, error: 'invalid_range', attemptId: id);
          }
          return null;
        }
      }
    }

    if (response.statusCode != 200 && !isPartial) {
      final requested = parseRetryAfter(response.headers['retry-after']);
      if (queueManaged && requested != null) _retryAfter[id!] = requested;
      if (queueManaged) {
        queue.fail(
          fileName,
          error: 'HTTP ${response.statusCode}',
          attemptId: id,
        );
      }
      // _showStatusError checks the context itself, and the failure is recorded
      // whether or not it can be shown.
      // ignore: use_build_context_synchronously
      _showStatusError(context, response.statusCode);
      return null;
    }

    final append = offset > 0 && isPartial;
    if (queueManaged) {
      queue.setValidator(
        fileName,
        etag: response.headers['etag'],
        lastModified: response.headers['last-modified'],
        attemptId: id,
      );
    }
    final contentLength = response.contentLength;
    final totalBytes = isPartial ? partialRange!.total : contentLength;
    final remainingBytes = isPartial ? partialRange!.length : contentLength;

    if (totalBytes != null) {
      // The temp volume only needs the bytes still to arrive on a resume. A
      // same-volume library promotion is a rename, so its free bytes are the
      // same ones already checked above. Cross-volume copies can need a second
      // full-file allocation; SAF has no destination volume to check yet.
      final neededTemp = (remainingBytes ?? totalBytes) + _spaceMarginBytes;
      final neededTarget = totalBytes + _spaceMarginBytes;
      final tempDir = p.dirname(tempPath);
      final freeTemp = await _availableSpace(tempDir);
      // SAF's destination is unknown until the user picks a URI. The temp
      // directory says nothing about that provider's free space.
      final sameVolume = destinationIsSaf
          ? null
          : await _sameStorageVolume(tempDir, targetDir);
      final freeTarget = !destinationIsSaf && sameVolume == false
          ? await _availableSpace(targetDir)
          : null;
      if ((freeTemp != null && neededTemp > freeTemp) ||
          (freeTarget != null && neededTarget > freeTarget)) {
        if (queueManaged) {
          queue.fail(fileName, error: 'no_space', attemptId: id);
        } else if (context != null && context.mounted) {
          // A share has no queue entry; without this it failed in silence.
          showSnackBar(
            context,
            icon: '🙊',
            message: L10n.of(context).download_no_space,
          );
        }
        return null;
      }
    }

    final sink = File(tempPath)
        .openWrite(mode: append ? FileMode.append : FileMode.write);
    var received = append ? offset : 0;
    var lastSample = DateTime.now();
    var lastReceived = 0;
    var speed = 0.0;

    try {
      await for (final chunk in response.stream.timeout(_idleTimeout)) {
        // Re-check every chunk: a pause that arrived before the abort hook was
        // attached still has to stop the transfer here. A share has no queue
        // entry, so its flags must not abort an unrelated transfer.
        if (queueManaged &&
            (queue.isCancelled(fileName, attemptId: id) ||
                queue.isPaused(fileName, attemptId: id))) {
          break;
        }
        sink.add(chunk);
        received += chunk.length;

        final elapsed = DateTime.now().difference(lastSample).inMilliseconds;
        if (elapsed >= 250) {
          final sample = (received - lastReceived) * 1000 / elapsed;
          speed = speed == 0 ? sample : speed * 0.6 + sample * 0.4;
          lastSample = DateTime.now();
          lastReceived = received;
          // Four updates per second are enough for a progress bar. Calling this
          // per socket chunk rebuilt the whole queue (and its badge) thousands of
          // times during one large transfer.
          if (queueManaged) {
            queue.progress(
              fileName,
              received,
              totalBytes,
              speed,
              attemptId: id,
            );
          }
        }
      }
    } finally {
      // The progress samples lag the stream by up to 250 ms; close first, then
      // record the bytes that are actually on disk. A pause is exactly when
      // the ledger must match the file for the next Range request.
      await sink.close();
      if (queueManaged && received > 0) {
        queue.recordBytes(fileName, received, totalBytes, attemptId: id);
      }
    }

    // A pause or a cancel that arrived mid-stream (before the abort hook was
    // attached, or between chunks): the partial file stays on disk for the
    // resume, and the entry is already parked. Not a failure.
    if (queueManaged &&
        (queue.isCancelled(fileName, attemptId: id) ||
            queue.isPaused(fileName, attemptId: id))) {
      return null;
    }

    if (totalBytes != null && received < totalBytes) {
      // Truncated transfer: keep the partial so a retry can resume it.
      if (queueManaged) {
        queue.fail(fileName, error: 'incomplete', attemptId: id);
      }
      return null;
    }

    keepTemp = true;
    return tempPath;
  } on Exception catch (e) {
    if (!queueManaged) return null;
    if (id != null && !queue.isAttemptCurrent(fileName, id)) {
      await _deleteTemp(tempPath);
    } else if (queue.isCancelled(fileName, attemptId: id)) {
      // User aborted from the queue: drop the partial file with the entry.
      await _deleteTemp(tempPath);
    } else if (!queue.isPaused(fileName, attemptId: id)) {
      queue.fail(fileName, error: _downloadError(e), attemptId: id);
    }
    return null;
  } finally {
    httpClient.close();
    // A share/auto-cache temp must never outlive a failed transfer.
    if (!queueManaged && !keepTemp) await _deleteTemp(tempPath);
  }
}
