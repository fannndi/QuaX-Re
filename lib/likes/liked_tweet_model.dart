import 'dart:async';
import 'dart:convert';

import 'package:flutter_triple/flutter_triple.dart';
import 'package:logging/logging.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:sqflite/sqflite.dart';

/// Local likes, scoped to the active account.
///
/// The tweet body lives once in `liked_tweet`; `account_like` records which
/// accounts liked it. A tweet liked by two accounts therefore keeps one copy of
/// its (large) JSON and two lightweight owner rows.
class LikedTweetModel extends Store<List<LikedTweet>> {
  static final log = Logger('LikedTweetModel');

  /// The local list is paged: a long-lived reader can have thousands of likes,
  /// and loading every full tweet body into one Store was 100+ MB of strings.
  static const pageSize = 50;

  LikedTweetModel() : super([]) {
    _localId = activeAccount.value?.localId;
    accountsRevision.addListener(_onAccountsChanged);
  }

  /// Every liked id of the active account, loaded cheaply alongside the first
  /// page. The post footer asks this on every rebuild of every visible card, so
  /// it cannot scan the paged state (which only holds the rows loaded so far).
  Set<String> _likedIds = const {};
  int _loadedCount = 0;
  bool _hasMore = false;
  bool _loadingMore = false;
  String? _localId;

  // Bumped when the account changes, so a page still in flight for the old
  // owner cannot append itself to the new account's list. [_mutation] catches
  // the narrower case where a like/unlike lands while a page is being read.
  int _epoch = 0;
  int _mutation = 0;
  bool _disposed = false;

  bool get hasMore => _hasMore;

  bool isLiked(String id) => _likedIds.contains(id);

  @override
  Future<void> destroy() async {
    _disposed = true;
    accountsRevision.removeListener(_onAccountsChanged);
    await super.destroy();
  }

  void _onAccountsChanged() {
    _epoch++;
    _mutation++;
    _localId = activeAccount.value?.localId;
    _likedIds = const {};
    _loadedCount = 0;
    _hasMore = false;
    _loadingMore = false;
    if (_disposed) return;

    update(const [], force: true);
    if (_localId != null) unawaited(listLikedTweets());
  }

  Future<(List<LikedTweet>, Set<String>)> _readFirstPage(String localId) {
    return Repository.read((db) async {
      final idRows = await db.rawQuery(
          'SELECT $columnTweetId FROM $tableAccountLike WHERE $columnAccountLocalId = ?', [localId]);
      final rows = await db.rawQuery('''
        SELECT lt.id, lt.user_id, lt.content
        FROM $tableAccountLike al
        JOIN $tableLikedTweet lt ON lt.id = al.$columnTweetId
        WHERE al.$columnAccountLocalId = ?
        ORDER BY al.$columnLikedAt DESC
        LIMIT ?
      ''', [localId, pageSize]);
      return (
        rows.map((e) => LikedTweet.fromMap(e)).toList(),
        idRows.map((e) => e[columnTweetId] as String).toSet()
      );
    });
  }

  Future<void> listLikedTweets() async {
    log.info('Listing liked tweets');

    final localId = _localId ?? activeAccount.value?.localId;
    if (localId == null) {
      _localId = null;
      _likedIds = const {};
      _loadedCount = 0;
      _hasMore = false;
      if (!_disposed) {
        update(const [], force: true);
        setError(null);
      }
      return;
    }

    _localId = localId;
    final epoch = _epoch;
    final mutation = _mutation;
    if (!_disposed) setLoading(true);
    try {
      final (rows, ids) = await _readFirstPage(localId);
      if (_disposed || epoch != _epoch) return;
      // A like or unlike landed while this page was being read; its in-memory
      // update is newer than the page, so don't overwrite it.
      if (mutation != _mutation) {
        setLoading(false);
        return;
      }
      _likedIds = ids;
      _loadedCount = rows.length;
      _hasMore = rows.length == pageSize;
      update(rows, force: true);
    } catch (e) {
      if (_disposed || epoch != _epoch) return;
      setError(e);
    } finally {
      if (!_disposed && epoch == _epoch) setLoading(false);
    }
  }

  /// Reloads without entering the loading state, so the current list stays visible
  /// until the fresh data is ready (used for pull-to-refresh).
  Future<void> refreshLikedTweets() async {
    log.info('Refreshing liked tweets');

    final localId = _localId ?? activeAccount.value?.localId;
    if (localId == null) return;

    final epoch = _epoch;
    final mutation = _mutation;
    final (rows, ids) = await _readFirstPage(localId);
    if (_disposed || epoch != _epoch || mutation != _mutation) return;

    _likedIds = ids;
    _loadedCount = rows.length;
    _hasMore = rows.length == pageSize;
    update(rows, force: true);
  }

  Future<void> loadMoreLikedTweets() async {
    if (!_hasMore || _loadingMore) return;
    _loadingMore = true;
    try {
      final localId = _localId;
      if (localId == null) return;
      final epoch = _epoch;
      final mutation = _mutation;

      final rows = await Repository.read((db) => db.rawQuery('''
        SELECT lt.id, lt.user_id, lt.content
        FROM $tableAccountLike al
        JOIN $tableLikedTweet lt ON lt.id = al.$columnTweetId
        WHERE al.$columnAccountLocalId = ?
        ORDER BY al.$columnLikedAt DESC
        LIMIT ? OFFSET ?
      ''', [localId, pageSize, _loadedCount]));

      if (_disposed || epoch != _epoch || mutation != _mutation) return;
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

    final localId = activeAccount.value?.localId;
    if (localId == null) return;

    final database = await Repository.writable();
    final encodedContent = jsonEncode(content);
    final alreadyLiked = _likedIds.contains(id);
    // UTC: the column also receives SQL CURRENT_TIMESTAMP (UTC) from the
    // migration backfills, and the list sorts these strings as text.
    final now = DateTime.now().toUtc().toIso8601String();

    await database.transaction((txn) async {
      await txn.insert(tableLikedTweet,
          {'id': id, 'user_id': user, 'content': encodedContent, columnLikedAt: now},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert(
          tableAccountLike,
          {columnAccountLocalId: localId, columnTweetId: id, columnLikedAt: now},
          conflictAlgorithm: ConflictAlgorithm.replace);
    });

    _mutation++;
    _likedIds = {..._likedIds, id};
    if (!alreadyLiked) _loadedCount++;
    update([LikedTweet(id: id, user: user, content: encodedContent), ...state.where((e) => e.id != id)],
        force: true);
  }

  Future<void> unlikeTweet(String id) async {
    log.fine('Unliking tweet $id');

    final localId = activeAccount.value?.localId;
    if (localId == null) return;

    final database = await Repository.writable();
    await database.transaction((txn) async {
      await txn.delete(tableAccountLike,
          where: '$columnAccountLocalId = ? AND $columnTweetId = ?', whereArgs: [localId, id]);
      final remaining = await txn.query(tableAccountLike,
          columns: [columnTweetId], where: '$columnTweetId = ?', whereArgs: [id], limit: 1);
      if (remaining.isEmpty) {
        await txn.delete(tableLikedTweet, where: 'id = ?', whereArgs: [id]);
      }
    });

    _mutation++;
    final wasVisible = state.any((e) => e.id == id);
    _likedIds = {..._likedIds}..remove(id);
    if (wasVisible && _loadedCount > 0) _loadedCount--;
    update(state.where((e) => e.id != id).toList(), force: true);
  }
}
