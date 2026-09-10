import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';

import 'package:quax/constants.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/ui/errors.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pref/pref.dart';
import 'package:share_plus/share_plus.dart';


/// Downloads [uri] under a live progress dialog (percent, transferred size and
/// speed, cancellable), then saves the file — into the configured directory,
/// or through the system save dialog — and offers a share sheet, so the file
/// can be sent straight to another app (WhatsApp, Telegram…).
Future<void> downloadUriToPickedFile(BuildContext context, Uri uri, String fileName,
    {required BasePrefService prefs}) async {
  var sanitizedFilename = p.basename(fileName.split('?').first);
  if (sanitizedFilename.isEmpty || sanitizedFilename.length > 180) {
    // Android rejects names this long in the media scanner.
    sanitizedFilename = 'media-${DateTime.now().millisecondsSinceEpoch}';
  }

  try {
    final tempPath = await _downloadToTemp(context, uri, sanitizedFilename);
    if (tempPath == null) return;

    try {
      final savePath = await _saveToDestination(context,
          file: tempPath, fileName: sanitizedFilename, prefs: prefs);
      if (savePath != null) {
        _showSuccess(context, savePath);
      }
    } finally {
      _deleteTemp(tempPath);
    }
  } catch (e) {
    if (context.mounted) {
      showSnackBar(context, icon: '🙊', message: e.toString());
    }
  }
}

Future<void> _deleteTemp(String? tempPath) async {
  try {
    if (tempPath != null && await File(tempPath).exists()) {
      await File(tempPath).delete();
    }
  } catch (_) {}
}

void _showSuccess(BuildContext context, String savedPath) {
  if (!context.mounted) return;
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

/// Downloads [uri] under the live progress dialog and opens the share sheet with
/// the file right away — the "send the meme straight to WhatsApp" shortcut.
Future<void> downloadAndShare(BuildContext context, Uri uri, String fileName,
    {required BasePrefService prefs}) async {
  var sanitizedFilename = p.basename(fileName.split('?').first);
  if (sanitizedFilename.isEmpty || sanitizedFilename.length > 180) {
    sanitizedFilename = 'media-${DateTime.now().millisecondsSinceEpoch}';
  }

  String? tempPath;
  try {
    tempPath = await _downloadToTemp(context, uri, sanitizedFilename);
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

void _showStatusError(BuildContext context, Object statusCode) {
  if (!context.mounted) return;
  showSnackBar(
      context,
      icon: '🙊',
      message: L10n.of(context)
          .unable_to_save_the_media_twitter_returned_a_status_of_response_statusCode(statusCode));
}

/// Saves the downloaded temp file to the user's destination and returns the
/// path (null when cancelled). Directory mode also registers the file with the
/// media scanner so it shows up in the gallery immediately.
Future<String?> _saveToDestination(BuildContext context,
    {required String file, required String fileName, required BasePrefService prefs}) async {
  final downloadType = prefs.get(optionDownloadType);
  final downloadPath = prefs.get(optionDownloadPath);

  // Hentoid-style library: everything lands in the hidden folder.
  if (downloadType == optionDownloadTypeLibrary && prefs.get(optionLibraryPath) is String) {
    final library = Directory(prefs.get<String>(optionLibraryPath)!);
    if (await library.exists()) {
      final savedFile = p.join(library.path, fileName);
      await File(file).copy(savedFile);
      return savedFile;
    }
    // The picked folder disappeared (uninstalled folder, sdcard changed...):
    // fall through to the system save dialog rather than losing the file.
  }

  // The "ask" mode (default) opens the system save dialog from the already
  // downloaded file, so nothing is keep in memory twice.
  if (downloadType == optionDownloadTypeAsk || downloadPath == '') {
    return FlutterFileDialog.saveFile(
      params: SaveFileDialogParams(sourceFilePath: file, fileName: fileName),
    );
  }

  final savedFile = p.join(downloadPath, fileName);
  await File(file).copy(savedFile);

  const platform = MethodChannel('browser_resolver');
  try {
    await platform.invokeMethod('scanMediaFile', {'path': savedFile});
  } catch (_) {}

  return savedFile;
}

/// Retries a failed queue entry. When the server honours Range requests the
/// download resumes from the bytes already on disk; otherwise it restarts.
Future<void> retryDownload(BuildContext context, DownloadQueueItem item,
    {required BasePrefService prefs}) async {
  final queue = DownloadsModel();
  queue.startResume(item.fileName);

  try {
    final tempPath = await _downloadToTemp(context, Uri.parse(item.url), item.fileName, resume: true);
    if (tempPath == null) return;

    try {
      final savePath = await _saveToDestination(context,
          file: tempPath, fileName: item.fileName, prefs: prefs);
      if (savePath != null) {
        _showSuccess(context, savePath);
      }
    } finally {
      _deleteTemp(tempPath);
    }
  } catch (e) {
    queue.fail(item.fileName, error: e.toString());
    if (context.mounted) {
      showSnackBar(context, icon: '🙊', message: e.toString());
    }
  }
}

/// Streams the response to a temporary file while feeding the downloads queue
/// (visible on the Downloads navbar tab) — Hentoid-style: the reader stays
/// usable while files download in the background. Cancels through the queue.
/// Failed downloads keep their partial file so a retry can resume.
/// Returns the temp path, or null when the download failed or was cancelled.
Future<String?> _downloadToTemp(BuildContext context, Uri uri, String fileName,
    {bool resume = false}) async {
  final tempDir = await getTemporaryDirectory();
  final tempPath = p.join(tempDir.path, 'quax-download-$fileName');
  final queue = DownloadsModel();
  final client = http.Client();
  final isVideo = fileName.contains(RegExp(r'\.(mp4|mov|webm|mkv|m4v)$', caseSensitive: false));
  if (!resume) {
    queue.register(fileName, uri.toString(), isVideo);
  }

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

    final request = http.Request('GET', uri);
    if (offset > 0) {
      request.headers['range'] = 'bytes=$offset-';
    }

    final response = await client.send(request);
    final isPartial = response.statusCode == 206;
    if (response.statusCode != 200 && !isPartial) {
      final message = 'HTTP ${response.statusCode}';
      queue.fail(fileName, error: message);
      _showStatusError(context, response.statusCode);
      return null;
    }

    final append = offset > 0 && isPartial;
    final contentLength = response.contentLength;
    final totalBytes = contentLength == null
        ? null
        : (append ? offset + contentLength : contentLength);

    final sink = File(tempPath).openWrite(mode: append ? FileMode.append : FileMode.write);
    var received = append ? offset : 0;
    var lastSample = DateTime.now();
    var lastReceived = 0;
    var speed = 0.0;

    await for (final chunk in response.stream) {
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
    }

    await sink.close();
    queue.markDone(fileName);
    return tempPath;
  } on Exception catch (e) {
    if (queue.isCancelled(fileName)) {
      // User aborted from the queue: drop the partial file with the entry.
      _deleteTemp(tempPath);
    } else {
      queue.fail(fileName, error: e.toString());
    }
    return null;
  }
}

