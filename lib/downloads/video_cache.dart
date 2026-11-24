import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';
import 'package:quax/downloads/atomic_copy.dart';
import 'package:quax/utils/atomic_file.dart';

class VideoCacheEntry {
  final String name;
  final String url;
  final int size;
  int touchedAt;

  VideoCacheEntry({
    required this.name,
    required this.url,
    required this.size,
    required this.touchedAt,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'size': size,
    'at': touchedAt,
  };

  factory VideoCacheEntry.fromJson(Map<String, dynamic> json) =>
      VideoCacheEntry(
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

  @visibleForTesting
  static Directory? debugDirectoryOverride;

  /// Only clips this short are worth fetching ahead of time.
  static const maxDurationMillis = 5 * 60 * 1000;

  /// Keyed by the canonical full URL, never by a lossy basename.
  final Map<String, VideoCacheEntry> _entries = {};
  bool _loaded = false;

  @visibleForTesting
  void resetForTests() {
    _entries.clear();
    _loaded = false;
    _writeInFlight = null;
    _dirty = false;
    _lastSaveAt = 0;
  }

  static bool isEligibleDuration(int? durationMillis) =>
      durationMillis != null &&
      durationMillis > 0 &&
      durationMillis <= maxDurationMillis;

  /// Usage stats for the settings screen.
  int get count => _entries.length;

  Future<Directory> directory() async {
    final dir =
        debugDirectoryOverride ??
        Directory(
          p.join((await getApplicationDocumentsDirectory()).path, _folder),
        );
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _ledger() async =>
      File(p.join((await directory()).path, _ledgerFile));

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;

    try {
      final file = await _ledger();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return;

      final dir = await directory();
      for (final raw in decoded.whereType<Map<String, dynamic>>()) {
        try {
          final entry = VideoCacheEntry.fromJson(raw);
          if (entry.name.isEmpty || entry.url.isEmpty) continue;
          // Legacy rows keep their existing basename file. The lookup key moves
          // to the URL hash without renaming or discarding cached bytes.
          if (await File(p.join(dir.path, entry.name)).exists()) {
            _entries[canonicalVideoUrl(entry.url)] = entry;
          }
        } catch (_) {
          // One bad row must not hide the remaining cache entries.
        }
      }
    } catch (_) {
      // A broken ledger just means an empty cache.
    }
  }

  int _lastSaveAt = 0;
  Future<void>? _writeInFlight;
  bool _dirty = false;

  Future<void> _save({bool force = false}) async {
    // A recency bump is not worth rewriting the whole ledger: localPathFor runs
    // up to three times per video tile that comes into view, and every one of
    // those used to jsonEncode every cached entry. Registering or evicting one
    // still saves immediately — that is the state the size limit depends on.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastSaveAt < 3000) return;
    _lastSaveAt = now;

    // Serialize writers: put() forces a save while localPathFor() may be
    // bumping recency. Overlapping writes used to share one temp path and
    // could delete the just-written ledger.
    if (_writeInFlight != null) {
      _dirty = true;
      return;
    }
    _writeInFlight = _writeLoop();
    try {
      await _writeInFlight;
      while (_dirty) {
        _dirty = false;
        await _writeLoop();
      }
    } finally {
      _writeInFlight = null;
    }
  }

  Future<void> _writeLoop() async {
    do {
      _dirty = false;
      try {
        final file = await _ledger();
        await writeAtomically(
          file,
          jsonEncode(_entries.values.map((e) => e.toJson()).toList()),
        );
      } catch (_) {
        // Best-effort.
      }
    } while (_dirty);
  }

  /// The cached file for a media URL, or null when it was never cached. A hit
  /// bumps the entry's recency for the LRU.
  Future<String?> localPathFor(String url) async {
    await load();

    final key = canonicalVideoUrl(url);
    final entry = _entries[key];
    if (entry == null || canonicalVideoUrl(entry.url) != key) return null;

    final file = File(p.join((await directory()).path, entry.name));
    if (!await file.exists()) {
      _entries.remove(key);
      await _save();
      return null;
    }

    entry.touchedAt = DateTime.now().millisecondsSinceEpoch;
    await _save();
    return file.path;
  }

  /// Registers a finished auto-cache fetch and enforces the size limit.
  Future<void> put(
    String url,
    File file, {
    required BasePrefService prefs,
  }) async {
    await load();

    final key = canonicalVideoUrl(url);
    final previous = _entries[key];
    final name = fileNameFor(url);
    final target = File(p.join((await directory()).path, name));
    await moveFileAtomically(file, target);

    _entries[key] = VideoCacheEntry(
      name: name,
      url: url,
      size: await target.length(),
      touchedAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (previous != null && previous.name != name) {
      await _deleteFile(previous.name);
    }
    await enforceLimit(prefs);
    // The new entry has to reach the ledger even when nothing was evicted.
    await _save(force: true);
  }

  Future<void> remove(String url) async {
    await load();

    final entry = _entries.remove(canonicalVideoUrl(url));
    if (entry != null) await _deleteFile(entry.name);
    await _save();
  }

  Future<void> clear() async {
    _entries.clear();
    _loaded = true;

    try {
      final dir = await directory();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Nothing to clear.
    }
  }

  Future<void> enforceLimit(BasePrefService prefs) async {
    await load();
    final capMb = prefs.get<int>(optionVideoCacheLimitMb) ?? 1024;
    final evicted = planEviction(
      _entries.values.toList(),
      capMb * 1024 * 1024,
    ).toSet();
    final removed = _entries.values
        .where((entry) => evicted.contains(entry.name))
        .toList();
    for (final entry in removed) {
      _entries.remove(canonicalVideoUrl(entry.url));
      await _deleteFile(entry.name);
    }
    if (removed.isNotEmpty) await _save(force: true);
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
  static List<String> planEviction(
    List<VideoCacheEntry> entries,
    int capBytes,
  ) {
    final sorted = [...entries]
      ..sort((a, b) => a.touchedAt.compareTo(b.touchedAt));
    var total = sorted.fold<int>(0, (sum, entry) => sum + entry.size);

    final evicted = <String>[];
    for (final entry in sorted) {
      if (total <= capBytes) break;
      evicted.add(entry.name);
      total -= entry.size;
    }
    return evicted;
  }

  /// Canonical identity for a media URL. Query parameters remain significant;
  /// only ordering, fragments, host case and default ports are normalized.
  @visibleForTesting
  static String canonicalVideoUrl(String value) {
    final uri = Uri.parse(value);
    var host = uri.host.toLowerCase();
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    final defaultPort =
        (uri.scheme.toLowerCase() == 'https' && uri.port == 443) ||
        (uri.scheme.toLowerCase() == 'http' && uri.port == 80);
    final query =
        uri.queryParametersAll.entries
            .map((entry) => MapEntry(entry.key, List.of(entry.value)))
            .toList()
          ..sort((a, b) {
            final key = a.key.compareTo(b.key);
            return key != 0
                ? key
                : a.value.join('\u0000').compareTo(b.value.join('\u0000'));
          });
    final encodedQuery = query
        .expand(
          (entry) => entry.value.map(
            (value) =>
                '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(value)}',
          ),
        )
        .join('&');
    return Uri(
      scheme: uri.scheme.toLowerCase(),
      userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
      host: host,
      port: defaultPort ? null : (uri.hasPort ? uri.port : null),
      path: uri.path,
      query: encodedQuery.isEmpty ? null : encodedQuery,
    ).toString();
  }

  /// A bounded file name derived from the hash of the canonical full URL.
  static String fileNameFor(String url) {
    final uri = Uri.tryParse(url);
    final extension = uri == null ? '' : p.extension(uri.path).toLowerCase();
    final safeExtension = RegExp(r'^\.[a-z0-9]{1,10}$').hasMatch(extension)
        ? extension
        : '';
    return '${sha256.convert(utf8.encode(canonicalVideoUrl(url))).toString()}$safeExtension';
  }
}
