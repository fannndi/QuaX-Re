import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';

import 'package:quax/constants.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/downloads/video_cache.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/library/library_model.dart';
import 'package:quax/tweet/video_metadata.dart';
import 'package:quax/ui/errors.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pref/pref.dart';
import 'package:share_plus/share_plus.dart';

const _storageChannel = MethodChannel('browser_resolver');

/// The single download worker: it pulls the first waiting entry (top of the
/// queue list = next to run, so dragging the queue reorders transfers), works
/// through it, then picks the next. The old FIFO chain is gone — a plain chain
/// could not honor pause, stop-all or reordering.
Future<void>? _worker;
BasePrefService? _workerPrefs;
final Map<String, BuildContext?> _workerContexts = {};

void _kickWorker() {
  if (_worker != null || _workerPrefs == null) return;
  _worker = _drainQueue().whenComplete(() => _worker = null);
}

Future<void> _drainQueue() async {
  final queue = DownloadsModel();
  while (true) {
    final next = queue.nextQueued;
    if (next == null) return;

    final context = _workerContexts.remove(next.fileName);
    await _runDownload(context, Uri.parse(next.url), next.fileName,
        prefs: _workerPrefs!, resume: true);
  }
}

/// A transfer that receives nothing for this long is considered stalled: the
/// connection is dropped and the entry becomes retryable (resuming where it
/// stopped), instead of hanging on a dead socket forever.
const _idleTimeout = Duration(seconds: 30);

/// Attempts per transfer: the first one plus transient-failure retries.
const _maxAttempts = 3;

/// Never start a transfer that cannot fit in the destination (+ headroom).
const _spaceMarginBytes = 64 * 1024 * 1024;

/// Auto-caching short videos runs on its own chain, behind the manual queue,
/// so a prefetch never delays a download the user actually asked for.
Future<void> _cacheChain = Future.value();

void _enqueueCache(Future<void> Function() task) {
  _cacheChain = _cacheChain.then((_) => task()).catchError((_) {});
}

/// Keeps a short video for later: fetches it into [VideoCache] in the
/// background, one clip at a time. Used when a video scrolls into view and the
/// matching setting is on; quietly gives up on anything (metered connection,
/// already cached or downloaded, failures) so the feed is never disturbed.
Future<void> cacheVideoAhead(
    {required Future<TweetVideoUrls> Function() urls, required BasePrefService prefs}) async {
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
      try {
        final temp = await _downloadToTemp(null, Uri.parse(target), 'cache-$name',
            targetDir: (await cache.directory()).path,
            onProgress: (received, total) {
          if (total != null && total > 0) {
            VideoCache().setProgress(target, received / total);
          }
        });
        if (temp == null) return;

        await cache.put(target, File(temp), prefs: prefs);
      } finally {
        // 1 clears the live percentage: done or failed, the label moves on.
        VideoCache().setProgress(target, 1);
      }
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
  final name = p.basename(fileName.split('?').first);
  if (name.isEmpty || name.length > 180) {
    // Android rejects names this long in the media scanner.
    return 'media-${DateTime.now().millisecondsSinceEpoch}';
  }
  return name;
}

bool _isVideo(String fileName) => fileName
    .contains(RegExp(r'\.(mp4|mov|webm|mkv|m4v|avi|ts|3gp|mpeg|mpg|wmv|flv|m2ts|ogv)$', caseSensitive: false));

/// Queues [uri] into the one-at-a-time download queue and, when its turn comes,
/// saves the file into the hidden library (or through the system dialog before
/// the library exists) and offers a share sheet. A transfer that is already
/// active for the same file is left alone instead of being re-queued twice.
Future<void> downloadUriToPickedFile(BuildContext context, Uri uri, String fileName,
    {required BasePrefService prefs}) async {
  final name = _sanitized(fileName);
  final queue = DownloadsModel();
  if (queue.isActive(name)) return;

  queue.register(name, uri.toString(), _isVideo(name));
  _workerPrefs = prefs;
  _workerContexts[name] = context;
  _kickWorker();
}

/// The actual transfer, run when the entry reaches the head of the queue.
/// Transient failures (stalls, dropped sockets, incomplete streams, 5xx) are
/// retried up to [_maxAttempts] with a growing pause, resuming from the bytes
/// already on disk. A null [context] means nobody is watching (an automatic
/// resume): unchanged progress and errors just stay in the queue.
Future<void> _runDownload(BuildContext? context, Uri uri, String fileName,
    {required BasePrefService prefs, bool resume = false}) async {
  final queue = DownloadsModel();
  // Cancelled (or removed) while waiting: its turn is skipped silently.
  if (!queue.contains(fileName) || queue.isCancelled(fileName)) return;

  try {
    final targetDir = await _targetDirectory(prefs);

    // An auto-cached copy makes both play and download instant: nothing to
    // fetch, the queue item just promotes the file into the library.
    final cache = VideoCache();
    final cachedPath = await cache.localPathFor(uri.toString());

    String? tempPath = cachedPath;
    if (cachedPath == null) {
      for (var attempt = 0; attempt < _maxAttempts; attempt++) {
        queue.startRunning(fileName);

        tempPath = await _downloadToTemp(context, uri, fileName,
            resume: resume || attempt > 0, targetDir: targetDir);
        if (tempPath != null) break;

        final item = queue.itemFor(fileName);
        if (item == null ||
            queue.isCancelled(fileName) ||
            queue.isPaused(fileName) ||
            !_isRetryable(item.error)) {
          return;
        }

        await Future.delayed(Duration(seconds: 3 * (attempt + 1)));
        if (!queue.contains(fileName) || queue.isCancelled(fileName) || queue.isPaused(fileName)) return;
      }
    }
    if (tempPath == null) return;

    var promoted = false;
    try {
      final savePath = await _saveToDestination(context,
          file: tempPath, fileName: fileName, prefs: prefs);
      if (savePath != null) {
        // Only now the file exists where the library scans: mark it done first,
        // so the done listeners see the finished entry, then celebrate.
        queue.markDone(fileName);
        _showSuccess(context, savePath);
        if (cachedPath != null) {
          promoted = true;
          await cache.remove(uri.toString());
        }
      } else {
        // The user cancelled the save dialog after a complete download.
        queue.remove(fileName);
      }
    } finally {
      // A cached file only leaves the cache once it landed in the library;
      // a cancelled save keeps it for the next attempt.
      if (cachedPath == null || promoted) _deleteTemp(tempPath);
    }
  } catch (e) {
    if (queue.isCancelled(fileName) || !queue.contains(fileName)) return;
    queue.fail(fileName, error: e.toString());
    if (context != null && context.mounted) {
      showSnackBar(context, icon: '🙊', message: e.toString());
    }
  }
}

/// True when an automatic retry can plausibly succeed. 4xx (except 408), a
/// full disk and stale interrupted markers are left to the manual Retry.
bool isRetryableDownloadError(String? error) => _isRetryable(error);

/// Re-queues a failed entry without any UI: the connectivity watcher uses it
/// when the network comes back.
void resumeDownload(DownloadQueueItem item, {required BasePrefService prefs}) {
  DownloadsModel().requeue(item.fileName);
  _workerPrefs = prefs;
  _kickWorker();
}

/// Server-side/client-side errors worth another automatic try. 4xx (except
/// 408) and a full disk never succeed on retry.
bool _isRetryable(String? error) {
  if (error == null || error.isEmpty) return false;
  if (error.startsWith('HTTP') && !error.startsWith('HTTP 408') && !error.startsWith('HTTP 5')) return false;
  if (error == 'no_space' || error == 'interrupted') return false;
  return true;
}

Future<String> _targetDirectory(BasePrefService prefs) async {
  final libraryPath = prefs.get<String>(optionLibraryPath);
  if (libraryPath != null && libraryPath.isNotEmpty) return libraryPath;
  return (await getTemporaryDirectory()).path;
}

Future<int?> _availableSpace(String path) async {
  try {
    return await _storageChannel.invokeMethod<int>('getAvailableSpace', {'path': path});
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

void _showSuccess(BuildContext? context, String savedPath) {
  if (context == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('✅ ${L10n.of(context).successfully_saved_the_media}'),
      action: SnackBarAction(
        label: L10n.of(context).share,
        onPressed: () async {
          await SharePlus.instance.share(ShareParams(files: [XFile(savedPath)]));
        },
      ),
    ),
  );
}

/// Downloads [uri] right away (no queue: a share is a foreground action) and
/// opens the share sheet with the file — the "send the meme straight to
/// WhatsApp" shortcut.
Future<void> downloadAndShare(BuildContext context, Uri uri, String fileName,
    {required BasePrefService prefs}) async {
  final sanitizedFilename = _sanitized(fileName);

  String? tempPath;
  try {
    final targetDir = (await getTemporaryDirectory()).path;
    tempPath = await _downloadToTemp(context, uri, sanitizedFilename, targetDir: targetDir);
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
          .unable_to_save_the_media_twitter_returned_a_status_of_response_statusCode(statusCode));
}

/// Saves the downloaded temp file to the user's destination and returns the
/// path (null when cancelled). The hidden library is the normal destination;
/// without a configured folder the system save dialog keeps downloads usable.
/// An existing file with the same name is never overwritten: the new copy gets
/// a timestamp suffix.
Future<String?> _saveToDestination(BuildContext? context,
    {required String file, required String fileName, required BasePrefService prefs}) async {
  final libraryPath = prefs.get<String>(optionLibraryPath);
  if (libraryPath != null && libraryPath.isNotEmpty) {
    final library = Directory(libraryPath);
    if (await library.exists()) {
      var savedFile = p.join(library.path, fileName);
      if (await File(savedFile).exists()) {
        savedFile = p.join(
            library.path,
            '${p.basenameWithoutExtension(fileName)}-${DateTime.now().millisecondsSinceEpoch}'
            '${p.extension(fileName)}');
      }
      await File(file).copy(savedFile);
      return savedFile;
    }
  }

  // The system dialog needs a live screen; an automatic resume has none.
  if (context == null || !context.mounted) return null;

  return FlutterFileDialog.saveFile(
    params: SaveFileDialogParams(sourceFilePath: file, fileName: fileName),
  );
}

/// Queues the retry of a failed entry through the same one-at-a-time queue
/// (first in line when the current transfer ends). When the server honours
/// Range requests the download resumes from the bytes already on disk.
Future<void> retryDownload(BuildContext context, DownloadQueueItem item,
    {required BasePrefService prefs}) async {
  DownloadsModel().requeue(item.fileName);

  _workerPrefs = prefs;
  _workerContexts[item.fileName] = context;
  _kickWorker();
}

http.Request _rangeRequest(Uri uri, int offset) {
  final request = http.Request('GET', uri);
  if (offset > 0) {
    request.headers['range'] = 'bytes=$offset-';
  }
  return request;
}

/// Streams the response to a temporary file while feeding the downloads queue
/// (visible on the Downloads navbar tab) — Hentoid-style: the reader stays
/// usable while files download in the background. Cancels through the queue.
/// Failed downloads keep their partial file so a retry can resume.
/// Returns the temp path, or null when the download failed or was cancelled.
Future<String?> _downloadToTemp(BuildContext? context, Uri uri, String fileName,
    {bool resume = false, required String targetDir, void Function(int received, int? total)? onProgress}) async {
  final tempDir = await getTemporaryDirectory();
  final tempPath = p.join(tempDir.path, 'quax-download-$fileName');
  final queue = DownloadsModel();
  final client = http.Client();

  queue.attachCancel(fileName, () {
    client.close(); // the stream loop surfaces as a ClientException and cleans up
  });

  try {
    // Resume only when the partial file still matches the recorded offset.
    var offset = resume ? queue.resumeOffsetFor(fileName) : 0;
    if (offset > 0) {
      final partial = File(tempPath);
      if (!await partial.exists() || await partial.length() != offset) {
        offset = 0;
      }
    }

    var response = await client.send(_rangeRequest(uri, offset));
    if (response.statusCode == 416 && offset > 0) {
      // The partial bytes no longer match the remote file: start over clean.
      await _deleteTemp(tempPath);
      offset = 0;
      response = await client.send(_rangeRequest(uri, 0));
    }

    final isPartial = response.statusCode == 206;
    if (response.statusCode != 200 && !isPartial) {
      queue.fail(fileName, error: 'HTTP ${response.statusCode}');
      _showStatusError(context, response.statusCode);
      return null;
    }

    final append = offset > 0 && isPartial;
    final contentLength = response.contentLength;
    final totalBytes = contentLength == null
        ? null
        : (append ? offset + contentLength : contentLength);

    if (totalBytes != null) {
      final free = await _availableSpace(targetDir);
      if (free != null && totalBytes + _spaceMarginBytes > free) {
        queue.fail(fileName, error: 'no_space');
        return null;
      }
    }

    final sink = File(tempPath).openWrite(mode: append ? FileMode.append : FileMode.write);
    var received = append ? offset : 0;
    var lastSample = DateTime.now();
    var lastReceived = 0;
    var speed = 0.0;

    await for (final chunk in response.stream.timeout(_idleTimeout)) {
      sink.add(chunk);
      received += chunk.length;

      final elapsed = DateTime.now().difference(lastSample).inMilliseconds;
      if (elapsed >= 250) {
        final sample = (received - lastReceived) * 1000 / elapsed;
        speed = speed == 0 ? sample : speed * 0.6 + sample * 0.4;
        lastSample = DateTime.now();
        lastReceived = received;
      }
      queue.progress(fileName, received, totalBytes, speed);
      onProgress?.call(received, totalBytes);
    }

    await sink.close();

    if (totalBytes != null && received < totalBytes) {
      // Truncated transfer: keep the partial so a retry can resume it.
      queue.fail(fileName, error: 'incomplete');
      return null;
    }

    return tempPath;
  } on Exception catch (e) {
    if (queue.isCancelled(fileName)) {
      // User aborted from the queue: drop the partial file with the entry.
      _deleteTemp(tempPath);
    } else if (queue.isPaused(fileName)) {
      // pause(): the entry is already parked and the partial file stays on
      // disk, so resuming sends a Range request from where it stopped.
    } else {
      queue.fail(fileName, error: e is TimeoutException ? 'timeout' : e.toString());
    }
    return null;
  } finally {
    client.close();
  }
}
