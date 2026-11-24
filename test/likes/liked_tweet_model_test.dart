import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/likes/liked_tweet_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    databaseName = 'quax_liked_tweet_model_test.db';
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await deleteDatabase(databaseName);
    await Repository().migrate();
    activeAccount.value = null;
    accountsRevision.value = 0;
  });

  tearDown(() async {
    await deleteDatabase(databaseName);
  });

  Future<void> addAccount(
    String id,
    String localId, {
    bool active = false,
  }) async {
    final db = await Repository.writable();
    await db.insert(tableAccounts, {
      'id': id,
      'auth_header': '{}',
      'screen_name': id,
      columnLocalId: localId,
      'is_active': active ? 1 : 0,
    });
  }

  Future<void> waitForLikes(LikedTweetModel model, int count) async {
    for (var i = 0; i < 200; i++) {
      if (!model.isLoading && model.state.length == count) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('The account switch did not reload the local likes in time');
  }

  Future<void> seedLikes(
    int count,
    String localId, {
    String prefix = 't',
  }) async {
    final db = await Repository.writable();
    for (var i = 0; i < count; i++) {
      final at = DateTime.utc(
        2026,
        1,
        1,
      ).add(Duration(minutes: i)).toIso8601String();
      await db.insert(tableLikedTweet, {
        'id': '$prefix$i',
        'content': '{}',
        columnLikedAt: at,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert(tableAccountLike, {
        columnAccountLocalId: localId,
        columnTweetId: '$prefix$i',
        columnLikedAt: at,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  test('Should page the active account likes and keep other accounts out', () async {
    await addAccount('a', 'local-a', active: true);
    await addAccount('b', 'local-b');
    await seedLikes(120, 'local-a');
    await seedLikes(2, 'local-b', prefix: 'b');
    await setActiveAccount('a');

    final model = LikedTweetModel();
    addTearDown(model.destroy);

    await model.listLikedTweets();

    expect(
      model.state,
      hasLength(LikedTweetModel.pageSize),
      reason:
          'Only the first page belongs in memory; loading every full tweet body was the '
          '100+ MB problem',
    );
    expect(model.hasMore, isTrue);
    expect(
      model.isLiked('t0'),
      isTrue,
      reason:
          'The id set is loaded separately and must cover rows beyond the first page, or the '
          'footer says an old like is not liked',
    );
    expect(
      model.isLiked('b0'),
      isFalse,
      reason:
          'The footer must not show another account\'s like as this account\'s',
    );

    await model.loadMoreLikedTweets();
    expect(model.state, hasLength(LikedTweetModel.pageSize * 2));
    expect(model.hasMore, isTrue);

    await model.loadMoreLikedTweets();
    expect(model.state, hasLength(120));
    expect(
      model.hasMore,
      isFalse,
      reason: 'A short page is the end; the pager must stop asking for more',
    );

    await setActiveAccount('b');
    await waitForLikes(model, 2);

    expect(
      model.state,
      hasLength(2),
      reason:
          'Switching accounts must reload the local tab instead of leaving the previous '
          'login\'s likes on screen',
    );
    expect(model.isLiked('b0'), isTrue);
    expect(
      model.isLiked('t0'),
      isFalse,
      reason: 'The old account\'s likes are no longer this account\'s likes',
    );
  });

  test(
    'Should share one tweet body between two accounts that liked it',
    () async {
      await addAccount('a', 'local-a', active: true);
      await addAccount('b', 'local-b');
      await setActiveAccount('a');

      final model = LikedTweetModel();
      addTearDown(model.destroy);

      expect(
        await model.likeTweet('new', null, {'text': 'hello'}),
        isTrue,
        reason: 'A like with an active account reports success',
      );
      expect(
        model.isLiked('new'),
        isTrue,
        reason: 'The footer index updates immediately after the write',
      );

      await setActiveAccount('b');
      await waitForLikes(model, 0);
      expect(
        model.isLiked('new'),
        isFalse,
        reason: 'A like is local to the account that tapped it',
      );

      expect(
        await model.likeTweet('new', null, {'text': 'hello again'}),
        isTrue,
        reason: 'The second account can like the same post independently',
      );
      final db = await Repository.read(
        (db) async => (
          await db.query(tableLikedTweet, where: 'id = ?', whereArgs: ['new']),
          await db.query(
            tableAccountLike,
            where: '$columnTweetId = ?',
            whereArgs: ['new'],
          ),
        ),
      );
      expect(
        db.$1,
        hasLength(1),
        reason: 'The tweet body is stored once, not once per account',
      );
      expect(
        db.$2,
        hasLength(2),
        reason: 'Both accounts keep their own owner row',
      );

      expect(
        await model.unlikeTweet('new'),
        isTrue,
        reason: 'An unlike with an active account reports success',
      );
      expect(
        model.isLiked('new'),
        isFalse,
        reason: 'The footer index removes the id immediately after the write',
      );

      await setActiveAccount('a');
      await waitForLikes(model, 1);
      expect(
        model.isLiked('new'),
        isTrue,
        reason: 'Removing account B\'s like must not remove account A\'s',
      );
    },
  );

  test('Should use a keyset cursor when a loaded row disappears before paging', () async {
    await addAccount('a', 'local-a', active: true);
    await seedLikes(120, 'local-a');
    await setActiveAccount('a');
    final model = LikedTweetModel();
    addTearDown(model.destroy);
    await model.listLikedTweets();

    final db = await Repository.writable();
    await db.delete(
      tableAccountLike,
      where: '$columnAccountLocalId = ? AND $columnTweetId = ?',
      whereArgs: ['local-a', 't119'],
    );
    await db.delete(tableLikedTweet, where: 'id = ?', whereArgs: ['t119']);

    await model.loadMoreLikedTweets();

    expect(
      model.state.map((tweet) => tweet.id),
      contains('t69'),
      reason:
          'OFFSET counts remaining rows, so deleting one already-shown like would skip '
          't69; a keyset cursor must continue after the previous page boundary',
    );
    expect(
      model.state.map((tweet) => tweet.id).toSet(),
      hasLength(100),
      reason: 'The keyset page neither skips nor repeats a row',
    );
  });

  test('Should keep rapid duplicate likes idempotent in memory', () async {
    await addAccount('a', 'local-a', active: true);
    await setActiveAccount('a');
    final model = LikedTweetModel();
    addTearDown(model.destroy);

    final results = await Future.wait([
      model.likeTweet('same', null, {'text': 'first'}),
      model.likeTweet('same', null, {'text': 'second'}),
    ]);

    expect(
      results,
      everyElement(isTrue),
      reason: 'Both queued duplicate taps complete for the same active owner',
    );
    expect(
      model.loadedCount,
      1,
      reason:
          'Two taps that overlap must not increase the loaded-row count twice',
    );
    expect(
      model.state.where((tweet) => tweet.id == 'same'),
      hasLength(1),
      reason:
          'A duplicate tap updates the existing card instead of adding another',
    );
  });

  test('Should return false and leave the new account untouched when a like crosses a switch', () async {
    await addAccount('a', 'local-a', active: true);
    await addAccount('b', 'local-b');
    await setActiveAccount('a');
    final entered = Completer<void>();
    final release = Completer<void>();
    final model = LikedTweetModel(
      debugMutationBarrier: (operation) async {
        expect(
          operation,
          'like',
          reason: 'The barrier pauses the like after its database transaction',
        );
        entered.complete();
        await release.future;
      },
    );
    addTearDown(model.destroy);

    final pending = model.likeTweet('old-account-like', null, {
      'text': 'hello',
    });
    await entered.future;
    await setActiveAccount('b');
    await waitForLikes(model, 0);
    release.complete();

    expect(
      await pending,
      isFalse,
      reason:
          'The write committed for A, but publishing it into B\'s list would show a like '
          'that account never made',
    );
    expect(
      model.isLiked('old-account-like'),
      isFalse,
      reason: 'The old account like must not enter the new account id set',
    );
    expect(
      model.state,
      isEmpty,
      reason:
          'The new account list stays empty after the stale mutation returns',
    );
  });

  test('Should catch refresh and paging failures and allow a retry', () async {
    await addAccount('a', 'local-a', active: true);
    await seedLikes(120, 'local-a');
    await setActiveAccount('a');
    final model = LikedTweetModel();
    addTearDown(model.destroy);
    await model.listLikedTweets();
    final db = await Repository.writable();

    await db.execute(
      'ALTER TABLE $tableLikedTweet RENAME TO liked_tweet_hidden',
    );
    await model.refreshLikedTweets();
    expect(
      model.error,
      isNotNull,
      reason:
          'Pull-to-refresh must surface a retryable store error instead of an unhandled '
          'future failure',
    );
    await model.loadMoreLikedTweets();
    expect(
      model.error,
      isNotNull,
      reason: 'A failed page is retained as a retryable store error',
    );
    await db.execute(
      'ALTER TABLE liked_tweet_hidden RENAME TO $tableLikedTweet',
    );

    await model.refreshLikedTweets();
    expect(
      model.error,
      isNull,
      reason: 'A successful refresh clears the previous retryable error',
    );
    expect(
      model.state,
      hasLength(50),
      reason: 'The successful refresh repaints the first page',
    );
    await model.loadMoreLikedTweets();
    expect(
      model.error,
      isNull,
      reason: 'A successful paging retry clears the previous page error',
    );
    expect(
      model.state,
      hasLength(100),
      reason: 'A failed page must reset its loading guard so the retry can run',
    );
  });
}
