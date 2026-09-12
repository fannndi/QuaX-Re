import 'package:flutter_test/flutter_test.dart';
import 'package:quax/utils/tweet_cache_index.dart';

void main() {
  setUp(() => TweetCacheIndex().clear());

  group('TweetCacheIndex', () {
    test('Should know the ids that were added', () {
      TweetCacheIndex().addAll(['1', '2']);

      expect(TweetCacheIndex().contains('1'), isTrue,
          reason: 'The cache label needs to find every tweet stored with a cached page');
      expect(TweetCacheIndex().contains('3'), isFalse,
          reason: 'A tweet that was never cached must not claim to be offline-readable');
      expect(TweetCacheIndex().contains(null), isFalse,
          reason: 'Tweets without an id can never match');
    });

    test('Should bump the revision only when a new id arrives', () {
      final before = TweetCacheIndex().revision.value;

      TweetCacheIndex().addAll(['1', '1', '2']);
      final after = TweetCacheIndex().revision.value;
      expect(after, greaterThan(before),
          reason: 'New ids must tell the footer labels to repaint');

      TweetCacheIndex().addAll(['1', '2']);
      expect(TweetCacheIndex().revision.value, after,
          reason: 'Re-adding known ids is a no-op and should not repaint anything');
    });

    test('Should forget everything on clear', () {
      TweetCacheIndex().addAll(['1', '2']);

      TweetCacheIndex().clear();

      expect(TweetCacheIndex().contains('1'), isFalse,
          reason: 'Clear cache drops the offline labels with the stored timelines');
    });
  });
}
