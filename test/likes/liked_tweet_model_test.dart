import 'package:flutter_test/flutter_test.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/likes/liked_tweet_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await deleteDatabase(databaseName);
    await Repository().migrate();
  });

  tearDown(() async {
    await deleteDatabase(databaseName);
  });

  Future<void> seedLikes(int count) async {
    final db = await Repository.writable();
    for (var i = 0; i < count; i++) {
      await db.insert(tableLikedTweet, {
        'id': 't$i',
        'content': '{}',
        'liked_at': DateTime.utc(2026, 1, 1).add(Duration(minutes: i)).toIso8601String(),
      });
    }
  }

  test('Should page local likes and still know every liked id', () async {
    await seedLikes(120);
    final model = LikedTweetModel();

    await model.listLikedTweets();

    expect(model.state, hasLength(LikedTweetModel.pageSize),
        reason: 'Only the first page belongs in memory; loading every full tweet body was the '
            '100+ MB problem');
    expect(model.hasMore, isTrue);
    expect(model.isLiked('t0'), isTrue,
        reason: 'The id set is loaded separately and must cover rows beyond the first page, or the '
            'footer says an old like is not liked');

    await model.loadMoreLikedTweets();
    expect(model.state, hasLength(LikedTweetModel.pageSize * 2));
    expect(model.hasMore, isTrue);

    await model.loadMoreLikedTweets();
    expect(model.state, hasLength(120));
    expect(model.hasMore, isFalse,
        reason: 'A short page is the end; the pager must stop asking for more');
  });

  test('Should put a new like first and remove it again', () async {
    await seedLikes(60);
    final model = LikedTweetModel();
    await model.listLikedTweets();

    await model.likeTweet('new', null, {'text': 'hello'});

    expect(model.isLiked('new'), isTrue);
    expect(model.state.first.id, 'new',
        reason: 'The newest like should be the first row the reader sees');

    await model.unlikeTweet('new');

    expect(model.isLiked('new'), isFalse);
    expect(model.state.any((e) => e.id == 'new'), isFalse);
  });
}
