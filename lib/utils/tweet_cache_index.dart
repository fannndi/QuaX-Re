import 'package:flutter/foundation.dart';

/// The tweets the app has on disk: the ids of every first page stored by
/// [TimelineCache] — the "local love" idea applied to timelines. The tweet
/// footer asks this to label a post as available offline; the revision notifier
/// tells those labels to repaint when the cache grows.
class TweetCacheIndex {
  static final TweetCacheIndex _instance = TweetCacheIndex._();

  factory TweetCacheIndex() => _instance;

  TweetCacheIndex._();

  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final Set<String> _ids = {};

  bool contains(String? id) => id != null && _ids.contains(id);

  void addAll(Iterable<String> ids) {
    final added = ids.where(_ids.add).length;
    if (added > 0) revision.value++;
  }

  void clear() {
    if (_ids.isEmpty) return;
    _ids.clear();
    revision.value++;
  }
}
