import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which tweets the app had already shown in previous sessions, so
/// every tweet can be labeled New (arrived since this launch) or Old (was
/// already there when the app was last open). The stored snapshot is the union
/// of what has ever been seen, trimmed to the most recent ids.
class TweetFreshnessIndex {
  static final TweetFreshnessIndex _instance = TweetFreshnessIndex._();

  factory TweetFreshnessIndex() => _instance;

  TweetFreshnessIndex._();

  static const _storeKey = 'freshness.v1.ids';
  static const _maxRemembered = 3000;

  /// Repaints the labels when the snapshot loads or grows.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Set<String> _baseline = {};
  final List<String> _seenNow = [];
  bool _loaded = false;
  Timer? _saveTimer;

  bool get isLoaded => _loaded;

  /// Call once at startup, before the feeds load.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      _baseline = (prefs.getStringList(_storeKey) ?? const []).toSet();
    } catch (_) {
      _baseline = {};
    }
    revision.value++;
  }

  /// Whether the tweet arrived after this app launch: not part of the snapshot
  /// taken when the app last ran.
  bool isNew(String? id) => id != null && _loaded && !_baseline.contains(id);

  /// Registers the ids the current session has loaded; they are merged into the
  /// snapshot (debounced), so next launch they count as old.
  void note(Iterable<String> ids) {
    if (!_loaded) return;

    var added = false;
    for (final id in ids) {
      if (id.isEmpty || _baseline.contains(id)) continue;
      if (_seenNow.contains(id)) continue;
      _seenNow.add(id);
      added = true;
    }
    if (!added) return;

    revision.value++;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    try {
      // The session baseline stays untouched (it defines New/Old for this
      // run); only the stored snapshot grows.
      final merged = <String>[..._baseline, ..._seenNow];
      final trimmed = merged.length > _maxRemembered
          ? merged.sublist(merged.length - _maxRemembered)
          : merged;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_storeKey, trimmed);
    } catch (_) {
      // The snapshot is best-effort; losing it only mislabels a session.
    }
  }
}
