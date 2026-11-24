import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:quax/constants.dart';
import 'package:quax/downloads/download_paths.dart';

/// A finished save destination. SAF results are content URIs, not paths.
class SavedMediaLocation {
  const SavedMediaLocation({this.path, this.uri});

  final String? path;
  final String? uri;

  bool get isUri => uri != null && uri!.isNotEmpty;

  factory SavedMediaLocation.parse(String? result) {
    if (result == null || result.isEmpty) return const SavedMediaLocation();
    if (result.startsWith('content://')) {
      return SavedMediaLocation(uri: result);
    }
    if (result.startsWith('/document/')) {
      // Older file-dialog builds returned only Uri.path. Without its provider
      // authority this cannot be reopened safely as either a path or a URI.
      return const SavedMediaLocation();
    }
    if (result.startsWith('file://')) {
      try {
        return SavedMediaLocation(path: Uri.parse(result).toFilePath());
      } catch (_) {
        return const SavedMediaLocation();
      }
    }
    return SavedMediaLocation(path: result);
  }
}

/// Materializes a SAF result in the app cache for share_plus, which needs a
/// file it can hand to another app. The URI itself is never passed to File.
Future<File?> shareableFileForSavedMedia(SavedMediaLocation saved) async {
  if (saved.path != null && saved.path!.isNotEmpty) {
    final path = saved.path!;
    if (path.startsWith('content://') || path.startsWith('/document/')) {
      return null;
    }
    final file = File(path);
    return await file.exists() ? file : null;
  }
  final uri = saved.uri;
  if (uri == null || uri.isEmpty) return null;

  File? temp;
  try {
    final name = p.basename(Uri.parse(uri).pathSegments.lastOrNull ?? 'media');
    temp = File(await shareTempPathFor(name.isEmpty ? 'media' : name));
    final copied = await quaxMethodChannel.invokeMethod<String>(
      'copyMediaUriToCache',
      {'uri': uri, 'outPath': temp.path},
    );
    if (copied == null || !await temp.exists() || await temp.length() == 0) {
      await _delete(temp);
      return null;
    }
    return temp;
  } catch (_) {
    if (temp != null) await _delete(temp);
    return null;
  }
}

Future<void> _delete(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    // Best-effort cache cleanup.
  }
}
