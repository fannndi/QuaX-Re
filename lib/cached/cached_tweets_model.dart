import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:quax/client/client.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/tweet/paginated_tweet_list.dart';
import 'package:quax/utils/tweet_freshness_index.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

/// Which home feed a cached chain came from. The Offline tab shows one
/// sub-tab per source, mirroring the home tabs.
enum CachedFeedSource { foryou, following }

extension CachedFeedSourceName on CachedFeedSource {
  String get key => name;

  static CachedFeedSource fromKey(String key) => CachedFeedSource.values
      .firstWhere((s) => s.key == key, orElse: () => CachedFeedSource.foryou);
}

/// The always-new home's archive: everything the home feeds load lands here
/// (full chain JSON, upserted by id), the Offline tab replays it per source,
/// and the feeds hide whatever was already seen in an earlier session.
class CachedTweetModel {
  static final CachedTweetModel _instance = CachedTweetModel._();

  factory CachedTweetModel() => _instance;

  CachedTweetModel._();

  /// Set to the source whose archive just changed underneath an open list (a
  /// clear), so only that tab re-reads it without being poked directly.
  final ValueNotifier<CachedFeedSource?> revision =
      ValueNotifier<CachedFeedSource?>(null);

  static const pageSize = 20;

  /// Splits a loaded page into what still belongs on the home (not in the
  /// freshness baseline) and what was already seen in an earlier session.
  static ({List<TweetChain> fresh, List<TweetChain> cached}) splitByFreshness(
    List<TweetChain> chains,
  ) {
    final index = TweetFreshnessIndex();
    final fresh = <TweetChain>[];
    final cached = <TweetChain>[];
    for (final chain in chains) {
      (index.isCached(chain.id) ? cached : fresh).add(chain);
    }
    return (fresh: fresh, cached: cached);
  }

  /// Archives a loaded home page: upserts every chain by id, so the freshest
  /// copy of a tweet (new counts, edited text) wins. Never throws into the
  /// feed's loading path — an archive failure must not blank the home.
  Future<void> archive(
    List<TweetChain> chains, {
    required CachedFeedSource source,
  }) async {
    if (chains.isEmpty) return;

    try {
      final database = await Repository.writable();
      await database.transaction((txn) async {
        for (final chain in chains) {
          final userId = chain.tweets.isEmpty
              ? null
              : chain.tweets.first.user?.idStr;
          await txn.insert(tableCachedTweet, {
            'id': chain.id,
            'user_id': userId,
            'source': source.key,
            'content': jsonEncode(chain.toJson()),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      });
    } catch (e) {
      debugPrint('CachedTweetModel archive failed: $e');
    }
  }

  /// One paged slice of the archive, newest first. The cursor is the row
  /// offset; null means the page after this one is empty.
  Future<TweetPageResult> loadPage({
    required CachedFeedSource source,
    required String? cursor,
  }) async {
    final offset = int.tryParse(cursor ?? '') ?? 0;

    final database = await Repository.readOnly();
    final rows = await database.query(
      tableCachedTweet,
      where: 'source = ?',
      whereArgs: [source.key],
      orderBy: 'cached_at DESC, id DESC',
      limit: pageSize,
      offset: offset,
    );
    final total = _countOf(
      await database.rawQuery(
        'SELECT COUNT(*) AS c FROM $tableCachedTweet WHERE source = ?',
        [source.key],
      ),
    );

    final chains = <TweetChain>[];
    for (final row in rows) {
      try {
        final archived = CachedTweet.fromMap(row);
        final chain = TweetChain.fromJson(
          jsonDecode(archived.content) as Map<String, dynamic>,
        );
        if (chain.tweets.isEmpty) continue;
        chains.add(chain);
      } catch (e) {
        // A corrupt row is skipped, not fatal.
        debugPrint('CachedTweetModel skip a corrupt archive row: $e');
      }
    }

    final next = offset + chains.length;
    return (chains: chains, nextCursor: next < total ? next.toString() : null);
  }

  /// Removes one source's archive entirely.
  Future<void> clear(CachedFeedSource source) async {
    final database = await Repository.writable();
    await database.delete(
      tableCachedTweet,
      where: 'source = ?',
      whereArgs: [source.key],
    );
    revision.value = source;
  }

  /// How many chains are archived per source, for diagnostics.
  Future<Map<String, int>> counts() async {
    final database = await Repository.readOnly();
    final rows = await database.rawQuery(
      'SELECT source, COUNT(*) AS c FROM $tableCachedTweet GROUP BY source',
    );
    final bySource = <String, int>{};
    for (final row in rows) {
      bySource[row['source'] as String? ?? '?'] = _countOf([row]);
    }
    return bySource;
  }

  int _countOf(List<Map<String, Object?>> rows) {
    final value = rows.isEmpty ? null : rows.first['c'];
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
