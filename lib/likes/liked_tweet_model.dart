import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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

  LikedTweetModel({@visibleForTesting this.debugMutationBarrier}) : super([]) {
    _localId = activeAccount.value?.localId;
    accountsRevision.addListener(_onAccountsChanged);
  }

  final Future<void> Function(String operation)? debugMutationBarrier;

  /// Every liked id of the active account, loaded cheaply alongside the first
  /// page. The post footer asks this on every rebuild of every visible card, so
  /// it cannot scan the paged state (which only holds the rows loaded so far).
  Set<String> _likedIds = const {};
  int _loadedCount = 0;
  bool _hasMore = false;
  bool _loadingMore = false;
  String? _localId;
  String? _cursorAt;
  String? _cursorId;

  // Bumped when the account changes, so a page still in flight for the old
  // owner cannot append itself to the new account's list. [_mutation] catches
  // the narrower case where a like/unlike lands while a page is being read.
  int _epoch = 0;
  int _mutation = 0;
  bool _disposed = false;
  Future<void> _mutationQueue = Future<void>.value();

  bool get hasMore => _hasMore;
  int get loadedCount => _loadedCount;

  bool isLiked(String id) => _likedIds.contains(id);

  /// Loads only the owner rows of the active account. The feed asks
  /// [isLiked] on every visible card, so the badge must be truthful before the
  /// Local tab has ever been opened; reading the tweet bodies here would pull
  /// a page of large JSON the feed does not display.
  Future<void> loadLikedIds() async {
    final localId = activeAccount.value?.localId;
    _localId = localId;
    if (localId == null) {
      _likedIds = const {};
      if (!_disposed) update(state, force: true);
      return;
    }

    final epoch = _epoch;
    final mutation = _mutation;
    try {
      final ids = await _readLikedIds(localId);
      if (_disposed || epoch != _epoch || mutation != _mutation) return;
      _likedIds = ids;
      update(state, force: true);
    } catch (e) {
      if (_disposed || epoch != _epoch) return;
      log.fine('Unable to load the local like ids', e);
    }
  }

  Future<Set<String>> _readLikedIds(String localId) {
    return Repository.read((db) async {
      final rows = await db.query(
        tableAccountLike,
        columns: [columnTweetId],
        where: '$columnAccountLocalId = ?',
        whereArgs: [localId],
      );
      return rows.map((row) => row[columnTweetId] as String).toSet();
    });
  }

  // Triple 2.1 copyWith treats null as "keep the old error", so _clearError()
  // cannot clear a failed refresh. Propagating an error event with a fresh
  // Triple is the supported Store hook that also updates selectError.
  void _clearError() {
    if (error == null) return;
    propagate(Triple<List<LikedTweet>>(state: state, event: TripleEvent.error));
  }

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
    _cursorAt = null;
    _cursorId = null;
    if (_disposed) return;

    _clearError();
    update(const [], force: true);
    if (_localId != null) unawaited(listLikedTweets());
  }

  void _rememberCursor(List<LikedTweet> rows) {
    if (rows.isEmpty) return;
    _cursorAt = rows.last.likedAt ?? '';
    _cursorId = rows.last.id;
  }

  Future<(List<LikedTweet>, Set<String>)> _readFirstPage(String localId) {
    return Repository.read((db) async {
      final idRows = await db.rawQuery(
        'SELECT $columnTweetId FROM $tableAccountLike WHERE $columnAccountLocalId = ?',
        [localId],
      );
      final rows = await db.rawQuery(
        '''
        SELECT lt.id, lt.user_id, lt.content, COALESCE(al.$columnLikedAt, '') AS liked_at
        FROM $tableAccountLike al
        JOIN $tableLikedTweet lt ON lt.id = al.$columnTweetId
        WHERE al.$columnAccountLocalId = ?
        ORDER BY al.$columnLikedAt DESC, al.$columnTweetId DESC
        LIMIT ?
      ''',
        [localId, pageSize],
      );
      return (
        rows.map((e) => LikedTweet.fromMap(e)).toList(),
        idRows.map((e) => e[columnTweetId] as String).toSet(),
      );
    });
  }

  Future<List<LikedTweet>> _readMorePage(String localId) {
    return Repository.read((db) async {
      final rows = await db.rawQuery(
        '''
        SELECT lt.id, lt.user_id, lt.content, COALESCE(al.$columnLikedAt, '') AS liked_at
        FROM $tableAccountLike al
        JOIN $tableLikedTweet lt ON lt.id = al.$columnTweetId
        WHERE al.$columnAccountLocalId = ?
          AND (COALESCE(al.$columnLikedAt, '') < ?
               OR (COALESCE(al.$columnLikedAt, '') = ? AND al.$columnTweetId < ?))
        ORDER BY al.$columnLikedAt DESC, al.$columnTweetId DESC
        LIMIT ?
      ''',
        [localId, _cursorAt ?? '', _cursorAt ?? '', _cursorId ?? '', pageSize],
      );
      return rows.map((e) => LikedTweet.fromMap(e)).toList();
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
      _cursorAt = null;
      _cursorId = null;
      if (!_disposed) {
        _clearError();
        update(const [], force: true);
        setLoading(false);
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
      _rememberCursor(rows);
      _clearError();
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
    try {
      final (rows, ids) = await _readFirstPage(localId);
      if (_disposed || epoch != _epoch || mutation != _mutation) return;

      _likedIds = ids;
      _loadedCount = rows.length;
      _hasMore = rows.length == pageSize;
      _rememberCursor(rows);
      _clearError();
      update(rows, force: true);
    } catch (e) {
      if (_disposed || epoch != _epoch) return;
      setError(e);
    }
  }

  Future<void> loadMoreLikedTweets() async {
    if (!_hasMore || _loadingMore) return;
    _loadingMore = true;
    final epoch = _epoch;
    final mutation = _mutation;
    try {
      final localId = _localId;
      if (localId == null) return;

      final rows = await _readMorePage(localId);

      if (_disposed || epoch != _epoch || mutation != _mutation) return;
      _loadedCount += rows.length;
      _hasMore = rows.length == pageSize;
      _rememberCursor(rows);
      _clearError();
      if (rows.isNotEmpty) update([...state, ...rows], force: true);
    } catch (e) {
      if (_disposed || epoch != _epoch) return;
      setError(e);
    } finally {
      if (epoch == _epoch) _loadingMore = false;
    }
  }

  Future<bool> likeTweet(
    String id,
    String? user,
    Map<String, dynamic> content,
  ) {
    log.fine('Liking tweet with the ID $id');

    final localId = activeAccount.value?.localId;
    final epoch = _epoch;
    if (localId == null) return Future.value(false);
    final encodedContent = jsonEncode(content);
    final result = _mutationQueue.then((_) async {
      if (_disposed ||
          epoch != _epoch ||
          activeAccount.value?.localId != localId) {
        return false;
      }
      final database = await Repository.writable();
      final wasVisible = state.any((tweet) => tweet.id == id);
      // UTC: the column also receives SQL CURRENT_TIMESTAMP (UTC) from the
      // migration backfills, and the list sorts these strings as text.
      final now = DateTime.now().toUtc().toIso8601String();

      await database.transaction((txn) async {
        await txn.insert(tableLikedTweet, {
          'id': id,
          'user_id': user,
          'content': encodedContent,
          columnLikedAt: now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.insert(tableAccountLike, {
          columnAccountLocalId: localId,
          columnTweetId: id,
          columnLikedAt: now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
      await debugMutationBarrier?.call('like');
      if (_disposed ||
          epoch != _epoch ||
          activeAccount.value?.localId != localId) {
        return false;
      }

      _mutation++;
      _likedIds = {..._likedIds, id};
      if (!wasVisible) _loadedCount++;
      update([
        LikedTweet(id: id, user: user, content: encodedContent, likedAt: now),
        ...state.where((e) => e.id != id),
      ], force: true);
      return true;
    });
    _mutationQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<bool> unlikeTweet(String id) {
    log.fine('Unliking tweet $id');

    final localId = activeAccount.value?.localId;
    final epoch = _epoch;
    if (localId == null) return Future.value(false);
    final result = _mutationQueue.then((_) async {
      if (_disposed ||
          epoch != _epoch ||
          activeAccount.value?.localId != localId) {
        return false;
      }
      final database = await Repository.writable();
      final wasVisible = state.any((tweet) => tweet.id == id);
      await database.transaction((txn) async {
        await txn.delete(
          tableAccountLike,
          where: '$columnAccountLocalId = ? AND $columnTweetId = ?',
          whereArgs: [localId, id],
        );
        final remaining = await txn.query(
          tableAccountLike,
          columns: [columnTweetId],
          where: '$columnTweetId = ?',
          whereArgs: [id],
          limit: 1,
        );
        if (remaining.isEmpty) {
          await txn.delete(tableLikedTweet, where: 'id = ?', whereArgs: [id]);
        }
      });
      await debugMutationBarrier?.call('unlike');
      if (_disposed ||
          epoch != _epoch ||
          activeAccount.value?.localId != localId) {
        return false;
      }

      _mutation++;
      _likedIds = {..._likedIds}..remove(id);
      if (wasVisible && _loadedCount > 0) _loadedCount--;
      update(state.where((e) => e.id != id).toList(), force: true);
      return true;
    });
    _mutationQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}
