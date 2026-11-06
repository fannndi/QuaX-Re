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

  Future<void> addAccount(String id, String localId, {bool active = false}) async {
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

  Future<void> seedLikes(int count, String localId, {String prefix = 't'}) async {
    final db = await Repository.writable();
    for (var i = 0; i < count; i++) {
      final at = DateTime.utc(2026, 1, 1).add(Duration(minutes: i)).toIso8601String();
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

    expect(model.state, hasLength(LikedTweetModel.pageSize),
        reason: 'Only the first page belongs in memory; loading every full tweet body was the '
            '100+ MB problem');
    expect(model.hasMore, isTrue);
    expect(model.isLiked('t0'), isTrue,
        reason: 'The id set is loaded separately and must cover rows beyond the first page, or the '
            'footer says an old like is not liked');
    expect(model.isLiked('b0'), isFalse,
        reason: 'The footer must not show another account\'s like as this account\'s');

    await model.loadMoreLikedTweets();
    expect(model.state, hasLength(LikedTweetModel.pageSize * 2));
    expect(model.hasMore, isTrue);

    await model.loadMoreLikedTweets();
    expect(model.state, hasLength(120));
    expect(model.hasMore, isFalse,
        reason: 'A short page is the end; the pager must stop asking for more');

    await setActiveAccount('b');
    await waitForLikes(model, 2);

    expect(model.state, hasLength(2),
        reason: 'Switching accounts must reload the local tab instead of leaving the previous '
            'login\'s likes on screen');
    expect(model.isLiked('b0'), isTrue);
    expect(model.isLiked('t0'), isFalse,
        reason: 'The old account\'s likes are no longer this account\'s likes');
  });

  test('Should share one tweet body between two accounts that liked it', () async {
    await addAccount('a', 'local-a', active: true);
    await addAccount('b', 'local-b');
    await setActiveAccount('a');

    final model = LikedTweetModel();
    addTearDown(model.destroy);

    await model.likeTweet('new', null, {'text': 'hello'});
    expect(model.isLiked('new'), isTrue);

    await setActiveAccount('b');
    await waitForLikes(model, 0);
    expect(model.isLiked('new'), isFalse,
        reason: 'A like is local to the account that tapped it');

    await model.likeTweet('new', null, {'text': 'hello again'});
    final db = await Repository.read((db) async => (
          await db.query(tableLikedTweet, where: 'id = ?', whereArgs: ['new']),
          await db.query(tableAccountLike, where: '$columnTweetId = ?', whereArgs: ['new'])
        ));
    expect(db.$1, hasLength(1),
        reason: 'The tweet body is stored once, not once per account');
    expect(db.$2, hasLength(2),
        reason: 'Both accounts keep their own owner row');

    await model.unlikeTweet('new');
    expect(model.isLiked('new'), isFalse);

    await setActiveAccount('a');
    await waitForLikes(model, 1);
    expect(model.isLiked('new'), isTrue,
        reason: 'Removing account B\'s like must not remove account A\'s');
  });
}
