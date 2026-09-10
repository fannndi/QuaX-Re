import 'dart:async';
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

/// Live state of a running download: bytes moved, the byte total when the
/// server answered one, and the smoothed transfer speed.
class DownloadProgress {
  final int receivedBytes;
  final int? totalBytes;
  final double speedBytesPerSecond;

  const DownloadProgress(this.receivedBytes, this.totalBytes, this.speedBytesPerSecond);
}

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

/// Streams the response to a temporary file while feeding a progress dialog,
/// so large videos show real numbers instead of looking frozen. Returns the
/// temp path, or null when the download failed or was cancelled.
Future<String?> _downloadToTemp(BuildContext context, Uri uri, String fileName) async {
  final tempDir = await getTemporaryDirectory();
  final tempPath = p.join(tempDir.path, 'quax-download-$fileName');
  final progress = StreamController<DownloadProgress>.broadcast();
  final finished = Completer<bool>(); // network has settled (success, error or cancel)
  final client = http.Client();
  final queue = DownloadsModel();
  final isVideo = fileName.contains(RegExp(r'\.(mp4|mov|webm|mkv|m4v)$', caseSensitive: false));
  queue.register(fileName, uri.toString(), isVideo);
  var cancelled = false;
  int? failedStatus;

  run() async {
    try {
      final response = await client.send(http.Request('GET', uri));
      if (response.statusCode != 200) {
        failedStatus = response.statusCode;
        return null;
      }

      final totalBytes = response.contentLength;
      final sink = File(tempPath).openWrite();
      var received = 0;
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
        progress.add(DownloadProgress(received, totalBytes, speed));
        queue.progress(
            fileName, received / 1048576, totalBytes == null ? null : totalBytes / 1048576,
            speed / 1048576);
      }

      await sink.close();
      queue.markDone(fileName);
      return tempPath;
    } catch (_) {
      // client.close() from the Cancel button lands here as a ClientException.
      _deleteTemp(tempPath);
      return null;
    } finally {
      if (!finished.isCompleted) {
        finished.complete(true); // settled: the dialog closes itself now
      }
    }
  }

  final network = run();
  final dialogFuture = showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _DownloadProgressDialog(
      progressStream: progress.stream,
      finished: finished.future,
      onCancel: () {
        cancelled = true;
        client.close();
      },
    ),
  );

  final result = await network;
  await progress.close();
  await dialogFuture;

  // Surface status errors once the dialog overlay is gone, so it is visible.
  if (!cancelled && failedStatus != null && context.mounted) {
    _showStatusError(context, failedStatus!);
    return null;
  }

  return cancelled ? null : result;
}

class _DownloadProgressDialog extends StatelessWidget {
  final Stream<DownloadProgress> progressStream;
  final Future<bool> finished;
  final VoidCallback onCancel;

  const _DownloadProgressDialog({
    required this.progressStream,
    required this.finished,
    required this.onCancel,
  });

  double? _percentOf(DownloadProgress? progress) {
    if (progress == null || progress.totalBytes == null || progress.totalBytes == 0) return null;
    return (progress.receivedBytes / progress.totalBytes!).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FutureBuilder<bool>(
      future: finished,
      builder: (context, finishedSnapshot) {
        // Either the network settled or the user cancelled: close the dialog so
        // the flow continues, whatever the outcome was.
        if (finishedSnapshot.connectionState == ConnectionState.done) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (Navigator.of(context).canPop()) Navigator.of(context).pop();
          });
        }

        return AlertDialog(
          title: Text(L10n.of(context).downloading_media),
          content: StreamBuilder<DownloadProgress>(
            stream: progressStream,
            builder: (context, snapshot) {
              final progress = snapshot.data;
              final percent = _percentOf(progress);
              final receivedMb = (progress?.receivedBytes ?? 0) / 1048576;

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (percent != null) LinearProgressIndicator(value: percent) else LinearProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    receivedMb == 0
                        ? '•'
                        : '$receivedMb MB'
                            '${progress?.totalBytes == null ? '' : ' / ${(progress!.totalBytes! / 1048576).toStringAsFixed(1)} MB'}'
                            '${progress == null || progress.speedBytesPerSecond == 0 ? '' : ' · ${(progress.speedBytesPerSecond / 1048576).toStringAsFixed(1)} MB/s'}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              );
            },
          ),
          actions: [
            TextButton(onPressed: onCancel, child: Text(L10n.of(context).cancel)),
          ],
        );
      },
    );
  }
}
