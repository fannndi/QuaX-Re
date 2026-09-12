import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';
import 'package:quax/downloads/video_cache.dart';
import 'package:quax/utils/timeline_cache.dart';

class StorageBreakdown {
  final int libraryBytes;
  final int videoCacheBytes;
  final int timelineCacheBytes;
  final int thumbnailBytes;
  final int videoCount;

  const StorageBreakdown({
    required this.libraryBytes,
    required this.videoCacheBytes,
    required this.timelineCacheBytes,
    required this.thumbnailBytes,
    required this.videoCount,
  });

  /// Everything the "clear cache" action can reclaim.
  int get cacheBytes => videoCacheBytes + timelineCacheBytes + thumbnailBytes;

  /// Timelines + thumbnails: the caches the video count does not describe.
  int get otherCacheBytes => timelineCacheBytes + thumbnailBytes;
}

/// Measures what the app uses on disk: the media library, the video cache and
/// the data caches, plus the cached-clip count for the usage stats.
Future<StorageBreakdown> computeStorageBreakdown(BasePrefService prefs) async {
  final videoCache = VideoCache();
  await videoCache.load();

  return StorageBreakdown(
    libraryBytes: await directorySize(prefs.get<String>(optionLibraryPath)),
    videoCacheBytes: await directorySize((await videoCache.directory()).path),
    timelineCacheBytes: await directorySize((await TimelineCache.directory()).path),
    thumbnailBytes: await directorySize(p.join((await getTemporaryDirectory()).path, 'thumbs')),
    videoCount: videoCache.count,
  );
}

/// Recursive size of [path]; 0 when it is missing or unreadable.
Future<int> directorySize(String? path) async {
  if (path == null || path.isEmpty) return 0;

  try {
    final dir = Directory(path);
    if (!await dir.exists()) return 0;

    var total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {
          // A single unreadable file must not fail the whole report.
        }
      }
    }
    return total;
  } catch (_) {
    return 0;
  }
}

/// Human-readable byte size (B/KB/MB/GB), one decimal from MB up.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';

  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';

  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';

  return '${(mb / 1024).toStringAsFixed(2)} GB';
}
