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
      // Pruning stats up to 200 files; doing that on every thread open is
      // wasted work while the reader is waiting for the screen.
      final lastPrune = _lastPruneAt;
      if (lastPrune == null || DateTime.now().difference(lastPrune) > _pruneInterval) {
        _lastPruneAt = DateTime.now();
        await prune(dir);
      }
    } catch (_) {
      // The cache is best-effort.
    }
  }

  static DateTime? _lastPruneAt;
  static const _pruneInterval = Duration(minutes: 10);

  /// Bounds the shelf. Threads are cached as they are opened, so without a
  /// ceiling the folder grows by one body per post the reader ever opens — and
  /// every file here is read whole when the offline shelf is shown.
  static const _maxEntries = 200;
  static const _maxBytes = 64 * 1024 * 1024;
  static const _maxAge = Duration(days: 30);

  static Future<void> prune(Directory dir) async {
    final entries = <({File file, DateTime modified, int size})>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      try {
        final stat = await entity.stat();
        entries.add((file: entity, modified: stat.modified, size: stat.size));
      } catch (_) {
        // Gone or unreadable: nothing for us to delete anyway.
      }
    }
    if (entries.isEmpty) return;

    final cutoff = DateTime.now().subtract(_maxAge);
    final fresh = <({File file, DateTime modified, int size})>[];
    for (final entry in entries) {
      if (entry.modified.isBefore(cutoff)) {
        await _delete(entry.file);
      } else {
        fresh.add(entry);
      }
    }
    fresh.sort((a, b) => b.modified.compareTo(a.modified));

    var totalBytes = fresh.fold<int>(0, (sum, entry) => sum + entry.size);
    var remaining = fresh.length;
    // Drop the oldest until both the entry count and the byte budget fit.
    for (var index = fresh.length - 1; index >= 0; index--) {
      if (remaining <= _maxEntries && totalBytes <= _maxBytes) break;
      final entry = fresh[index];
      await _delete(entry.file);
      remaining--;
      totalBytes -= entry.size;
    }
  }

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // Another writer may have taken it already.
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

