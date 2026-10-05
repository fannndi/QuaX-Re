import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// File-backed cache of a post's thread body (the raw GraphQL response), so a
/// thread can paint what the reader already had the moment it opens and then
/// revalidate it — X answers fresh data moments later, but nobody stares at a
/// spinner for content they already saw. Files, not preferences: bodies are
/// hundreds of KB and must never bloat the settings store.
class TimelineCache {
  static const _folder = 'timeline_cache';

  static String keyFor(String feed) => 'timeline.v1.$feed';

  static Future<Directory> directory() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, _folder));
    await dir.create(recursive: true);
    return dir;
  }

  /// Hashes the key into a safe file name (keys contain dots and dots are fine,
  /// but account-scoped keys can carry arbitrary characters).
  static String _fileName(String key) =>
      key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// The cached body, or null when it is missing or unreadable. [maxAge] bounds
  /// what counts as fresh; null shows the stored page regardless of age (the
  /// offline shelf), while the instant-paint preview keeps a short window.
  static Future<String?> read(String key, {Duration? maxAge}) async {
    try {
      final file = File(p.join((await directory()).path, _fileName(key)));
      if (!await file.exists()) return null;

      final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (maxAge != null) {
        final savedAt = DateTime.fromMillisecondsSinceEpoch(decoded['at'] as int? ?? 0);
        if (DateTime.now().difference(savedAt) > maxAge) return null;
      }
      return decoded['body'] as String?;
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String key, String body) async {
    try {
      final dir = await directory();
      final file = File(p.join(dir.path, _fileName(key)));
      await file.writeAsString(jsonEncode({'at': DateTime.now().millisecondsSinceEpoch, 'body': body}));
      await _prune(dir);
    } catch (_) {
      // The cache is best-effort.
    }
  }

  /// Bounds the shelf. Threads are cached as they are opened, so without a
  /// ceiling the folder grows by one body per post the reader ever opens — and
  /// every file here is read whole when the offline shelf is shown.
  static const _maxEntries = 200;
  static const _maxAge = Duration(days: 30);

  static Future<void> _prune(Directory dir) async {
    final entries = <MapEntry<File, DateTime>>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      try {
        entries.add(MapEntry(entity, (await entity.stat()).modified));
      } catch (_) {
        // Gone or unreadable: nothing for us to delete anyway.
      }
    }
    if (entries.isEmpty) return;

    entries.removeWhere((entry) => entry.value.isBefore(DateTime.now().subtract(_maxAge)));
    entries.sort((a, b) => b.value.compareTo(a.value));

    for (final stale in entries.skip(_maxEntries)) {
      try {
        await stale.key.delete();
      } catch (_) {
        // Another writer may have taken it already.
      }
    }
  }

  /// Drops every stored timeline: the next visit refetches everything, and the
  /// previews rebuild from the fresh responses.
  static Future<void> clearAll() async {
    try {
      final dir = await directory();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // Nothing to clear.
    }
  }
}

