import 'dart:convert';

import 'package:flutter_triple/flutter_triple.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:logging/logging.dart';
import 'package:sqflite/sqflite.dart';

class LikedTweetModel extends Store<List<LikedTweet>> {
  static final log = Logger('LikedTweetModel');

  /// The local list is paged: a long-lived reader can have thousands of likes,
  /// and loading every full tweet body into one Store was 100+ MB of strings.
  static const pageSize = 50;

  LikedTweetModel() : super([]);

  /// Every liked id, loaded cheaply alongside the first page. The post footer
  /// asks this on every rebuild of every visible card, so it cannot scan the
  /// paged state (which only holds the rows loaded so far).
  Set<String> _likedIds = const {};
  int _loadedCount = 0;
  bool _hasMore = false;
  bool _loadingMore = false;

  bool get hasMore => _hasMore;

  bool isLiked(String id) => _likedIds.contains(id);

  Future<(List<LikedTweet>, Set<String>)> _readFirstPage() async {
    return Repository.read((db) async {
      final idRows = await db.query(tableLikedTweet, columns: ['id']);
      final rows = await db.query(tableLikedTweet, orderBy: 'liked_at DESC', limit: pageSize);
      return (rows.map((e) => LikedTweet.fromMap(e)).toList(),
          idRows.map((e) => e['id'] as String).toSet());
    });
  }

  Future<void> listLikedTweets() async {
    log.info('Listing liked tweets');

    await execute(() async {
      final (rows, ids) = await _readFirstPage();
      _likedIds = ids;
      _loadedCount = rows.length;
      _hasMore = rows.length == pageSize;
      return rows;
    });
  }

  /// Reloads without entering the loading state, so the current list stays visible
  /// until the fresh data is ready (used for pull-to-refresh).
  Future<void> refreshLikedTweets() async {
    log.info('Refreshing liked tweets');

    final (rows, ids) = await _readFirstPage();
    _likedIds = ids;
    _loadedCount = rows.length;
    _hasMore = rows.length == pageSize;
    update(rows, force: true);
  }

  Future<void> loadMoreLikedTweets() async {
    if (!_hasMore || _loadingMore) return;
    _loadingMore = true;
    try {
      final rows = await Repository.read((db) => db.query(tableLikedTweet,
          orderBy: 'liked_at DESC', limit: pageSize, offset: _loadedCount));
      final more = rows.map((e) => LikedTweet.fromMap(e)).toList();
      _loadedCount += more.length;
      _hasMore = more.length == pageSize;
      if (more.isNotEmpty) update([...state, ...more], force: true);
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> likeTweet(String id, String? user, Map<String, dynamic> content) async {
    log.fine('Liking tweet with the ID $id');

    var database = await Repository.writable();
    var encodedContent = jsonEncode(content);
    final alreadyLiked = _likedIds.contains(id);

    // Idempotent: the same tweet can surface twice in a feed (e.g. a pinned/retweeted
    // copy and its older chronological one), so a second "like" of an id already present
    // must not throw on the primary key nor duplicate the in-memory entry.
    await database.insert(tableLikedTweet, {'id': id, 'user_id': user, 'content': encodedContent},
        conflictAlgorithm: ConflictAlgorithm.replace);
    _likedIds = {..._likedIds, id};
    if (!alreadyLiked) _loadedCount++;
    update([LikedTweet(id: id, user: user, content: encodedContent), ...state.where((e) => e.id != id)],
        force: true);
  }

  Future<void> unlikeTweet(String id) async {
    log.fine('Unliking tweet $id');

    var database = await Repository.writable();

    await database.delete(tableLikedTweet, where: 'id = ?', whereArgs: [id]);
    final wasVisible = state.any((e) => e.id == id);
    _likedIds = {..._likedIds}..remove(id);
    if (wasVisible && _loadedCount > 0) _loadedCount--;
    update(state.where((e) => e.id != id).toList(), force: true);
  }
}
