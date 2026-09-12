import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// File-backed cache of a timeline's first page (the raw GraphQL body), so a
/// feed can paint its last content the instant the app opens and then
/// revalidate it — X answers fresh data moments later, but the reader never
/// stares at a spinner for content it already had. Files, not preferences:
/// bodies are hundreds of KB and must never bloat the settings store.
class TimelineCache {
  static const _folder = 'timeline_cache';

  static String keyFor(String feed) => 'timeline.v1.$feed';

  static Future<Directory> _dir() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, _folder));
    await dir.create(recursive: true);
    return dir;
  }

  /// Hashes the key into a safe file name (keys contain dots and dots are fine,
  /// but account-scoped keys can carry arbitrary characters).
  static String _fileName(String key) =>
      key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// The cached body, or null when it is missing, unreadable or older than
  /// [maxAge]. Failures are silent: a cold cache only costs a spinner.
  static Future<String?> read(String key, {required Duration maxAge}) async {
    try {
      final file = File(p.join((await _dir()).path, _fileName(key)));
      if (!await file.exists()) return null;

      final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final savedAt = DateTime.fromMillisecondsSinceEpoch(decoded['at'] as int? ?? 0);
      if (DateTime.now().difference(savedAt) > maxAge) return null;

      return decoded['body'] as String?;
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String key, String body) async {
    try {
      final file = File(p.join((await _dir()).path, _fileName(key)));
      await file.writeAsString(jsonEncode({'at': DateTime.now().millisecondsSinceEpoch, 'body': body}));
    } catch (_) {
      // The cache is best-effort.
    }
  }

  /// Drops every stored timeline: the next visit refetches everything, and the
  /// previews rebuild from the fresh responses.
  static Future<void> clearAll() async {
    try {
      final dir = await _dir();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // Nothing to clear.
    }
  }
}
