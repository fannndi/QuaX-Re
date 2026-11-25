import 'package:flutter/foundation.dart';
import 'package:quax/utils/lru_cache.dart';

/// Cached answers to "is this media URL already in the library?".
///
/// The feed asks this for every visible media item, while [LibraryModel] may
/// touch the filesystem and migrate a legacy URL mapping on a miss. Caching the
/// future keeps scrolling from turning into repeated disk scans. [revision]
/// tells the badges to ask again after a download, delete, import, or storage
/// move changed what the library holds.
class LibraryPresence {
  LibraryPresence._();

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);
  static final LruCache<String, Future<bool>> _lookups = LruCache(400);

  static Future<bool> contains({
    required String root,
    required String url,
    required Future<String?> Function() lookup,
  }) {
    if (root.isEmpty || url.isEmpty) return Future<bool>.value(false);

    final key = '$root\u0000$url';
    final cached = _lookups.get(key);
    if (cached != null) return cached;

    final future = lookup().then(
      (path) => path != null && path.isNotEmpty,
      onError: (Object _) => false,
    );
    _lookups.set(key, future);
    return future;
  }

  /// Drops every cached answer and repaints the badges.
  static void invalidate() {
    _lookups.clear();
    revision.value++;
  }

  @visibleForTesting
  static void resetForTesting() {
    _lookups.clear();
    revision.value = 0;
  }
}
