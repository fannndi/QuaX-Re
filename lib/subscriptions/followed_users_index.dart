import 'package:flutter/foundation.dart';

/// In-memory index of the locally followed (subscribed) user ids, so tweet
/// headers can label posts from accounts the reader follows. A subscriptions
/// reload refreshes it; the revision tells the labels to repaint.
class FollowedUsersIndex {
  static final FollowedUsersIndex _instance = FollowedUsersIndex._();

  factory FollowedUsersIndex() => _instance;

  FollowedUsersIndex._();

  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final Set<String> _ids = {};

  bool contains(String? id) => id != null && _ids.contains(id);

  void replaceAll(Iterable<String> ids) {
    _ids
      ..clear()
      ..addAll(ids);
    revision.value++;
  }
}
