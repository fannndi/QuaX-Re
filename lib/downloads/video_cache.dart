import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';

class VideoCacheEntry {
  final String name;
  final String url;
  final int size;
  int touchedAt;

  VideoCacheEntry({required this.name, required this.url, required this.size, required this.touchedAt});

  Map<String, dynamic> toJson() => {'name': name, 'url': url, 'size': size, 'at': touchedAt};

  factory VideoCacheEntry.fromJson(Map<String, dynamic> json) => VideoCacheEntry(
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
        size: json['size'] as int? ?? 0,
        touchedAt: json['at'] as int? ?? 0,
      );
}

/// Auto-cache of short videos: fetched ahead of time while scrolling, so play
/// and download start instantly — and keep working offline. It lives in the
/// app's private documents (never the library folder) and is bounded by the
/// size limit from the settings with LRU eviction, because caching videos is
/// data-hungry by nature.
class VideoCache {
  static final VideoCache _instance = VideoCache._();

  factory VideoCache() => _instance;

  VideoCache._();

  static const _folder = 'video_cache';
  static const _ledgerFile = 'video_cache.json';

  /// Only clips this short are worth fetching ahead of time.
  static const maxDurationMillis = 5 * 60 * 1000;

  final Map<String, VideoCacheEntry> _entries = {};
  bool _loaded = false;

  static bool isEligibleDuration(int? durationMillis) =>
      durationMillis != null && durationMillis > 0 && durationMillis <= maxDurationMillis;

  /// Whether a completed cache file exists (sync view of [load]'s index).
  bool isCached(String url) => _entries.containsKey(fileNameFor(url));

  /// Usage stats for the settings screen.
  int get count => _entries.length;

  int get totalBytes => _entries.values.fold(0, (sum, entry) => sum + entry.size);

  Future<Directory> directory() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(root.path, _folder));
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _ledger() async => File(p.join((await directory()).path, _ledgerFile));

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;

    try {
      final file = await _ledger();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return;

      for (final raw in decoded.whereType<Map<String, dynamic>>()) {
        final entry = VideoCacheEntry.fromJson(raw);
        if (entry.name.isEmpty) continue;
        if (await File(p.join((await directory()).path, entry.name)).exists()) {
          _entries[entry.name] = entry;
        }
      }
    } catch (_) {
      // A broken ledger just means an empty cache.
    }
  }

  Future<void> _save() async {
    try {
      final file = await _ledger();
      await file.writeAsString(jsonEncode(_entries.values.map((e) => e.toJson()).toList()));
    } catch (_) {
      // Best-effort.
    }
  }

  /// The cached file for a media URL, or null when it was never cached. A hit
  /// bumps the entry's recency for the LRU.
  Future<String?> localPathFor(String url) async {
    await load();

    final name = fileNameFor(url);
    final entry = _entries[name];
    if (entry == null) return null;

    final file = File(p.join((await directory()).path, name));
    if (!await file.exists()) {
      _entries.remove(name);
      await _save();
      return null;
    }

    entry.touchedAt = DateTime.now().millisecondsSinceEpoch;
    await _save();
    return file.path;
  }

  /// Registers a finished auto-cache fetch and enforces the size limit.
  Future<void> put(String url, File file, {required BasePrefService prefs}) async {
    await load();

    final name = fileNameFor(url);
    final target = File(p.join((await directory()).path, name));
    try {
      await file.rename(target.path);
    } on FileSystemException {
      await file.copy(target.path);
      await file.delete();
    }

    _entries[name] = VideoCacheEntry(
      name: name,
      url: url,
      size: await target.length(),
      touchedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await enforceLimit(prefs);
  }

  Future<void> remove(String url) async {
    await load();

    final name = fileNameFor(url);
    _entries.remove(name);
    await _deleteFile(name);
    await _save();
  }

  Future<void> clear() async {
    _entries.clear();
    _loaded = true;

    try {
      final dir = await directory();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // Nothing to clear.
    }
  }

  Future<void> enforceLimit(BasePrefService prefs) async {
    final capMb = prefs.get<int>(optionVideoCacheLimitMb) ?? 1024;
    final evicted = planEviction(_entries.values.toList(), capMb * 1024 * 1024);
    for (final name in evicted) {
      _entries.remove(name);
      await _deleteFile(name);
    }
    if (evicted.isNotEmpty) await _save();
  }

  Future<void> _deleteFile(String name) async {
    try {
      final file = File(p.join((await directory()).path, name));
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Already gone.
    }
  }

  /// Pure LRU planner: the oldest entries to drop so the rest fits [capBytes].
  static List<String> planEviction(List<VideoCacheEntry> entries, int capBytes) {
    final sorted = [...entries]..sort((a, b) => a.touchedAt.compareTo(b.touchedAt));
    var total = sorted.fold<int>(0, (sum, entry) => sum + entry.size);

    final evicted = <String>[];
    for (final entry in sorted) {
      if (total <= capBytes) break;
      evicted.add(entry.name);
      total -= entry.size;
    }
    return evicted;
  }

  /// A safe file name derived from the URL basename; account URLs can carry
  /// characters Android dislikes in file names.
  static String fileNameFor(String url) {
    final name = p.basename(url.split('?').first);
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (safe.isEmpty) return 'video-${url.hashCode}';
    if (safe.length <= 120) return safe;
    return '${safe.substring(safe.length - 120)}';
  }
}
