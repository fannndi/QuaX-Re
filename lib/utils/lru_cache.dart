import 'dart:collection';

/// A tiny least-recently-used map: reading a key makes it the newest, and the
/// oldest entry is dropped once [capacity] is exceeded. Used to keep decoded
/// models around for list items that rebuild while scrolling.
class LruCache<K, V> {
  final int capacity;
  final LinkedHashMap<K, V> _entries = LinkedHashMap<K, V>();

  LruCache(this.capacity) : assert(capacity > 0, 'A zero-capacity cache would drop every entry');

  V? get(K key) {
    final value = _entries.remove(key);
    if (value == null) return null;

    _entries[key] = value;
    return value;
  }

  void set(K key, V value) {
    _entries.remove(key);
    _entries[key] = value;

    if (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  int get length => _entries.length;

  void clear() => _entries.clear();
}
