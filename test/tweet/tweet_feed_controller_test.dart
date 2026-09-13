import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/client.dart';
import 'package:quax/tweet/paginated_tweet_list.dart';

TweetChain chain(String id) => TweetChain(id: id, tweets: const [], isPinned: false);

TweetPageResult page(List<String> ids, String? cursor) =>
    (chains: ids.map(chain).toList(), nextCursor: cursor);

void main() {
  group('TweetFeedController.applyFirstPage()', () {
    test('Should keep the loaded items when the refresh answers empty', () async {
      final controller = TweetFeedController();
      addTearDown(controller.dispose);
      controller.loader = (cursor) async => page(['1', '2'], 'c1');

      controller.applyFirstPage(await controller.fetchFirstPage());
      final applied = controller.applyFirstPage(page([], null));

      expect(applied, isFalse,
          reason: 'An empty first page changed nothing, so the caller should not close the '
              'freshness round');
      expect(controller.items?.map((chain) => chain.id), ['1', '2'],
          reason: 'The "latest" feed answers empty when nothing recent happened; wiping the '
              'visible tweets for that reads as a broken tab');
    });

    test('Should prepend the refreshed page when mergeOnRefresh is set', () async {
      final controller = TweetFeedController(mergeOnRefresh: true);
      addTearDown(controller.dispose);

      controller.applyFirstPage(page(['1', '2'], 'c1'));
      controller.applyFirstPage(page(['0'], 'c0'));

      expect(controller.items?.map((chain) => chain.id), ['0', '1', '2'],
          reason: 'A chronological refresh should slide new tweets on top and keep the ones '
              'below, so the feed never shortens to the handful of newer posts');
    });

    test('Should not duplicate a tweet that a refreshed page repeats', () async {
      final controller = TweetFeedController(mergeOnRefresh: true);
      addTearDown(controller.dispose);

      controller.applyFirstPage(page(['1', '2'], 'c1'));
      controller.applyFirstPage(page(['2', '3'], 'c2'));

      expect(controller.items?.map((chain) => chain.id), ['2', '3', '1'],
          reason: 'The repeated tweet should move to the new position instead of appearing twice');
    });

    test('Should replace the items when mergeOnRefresh is off', () async {
      final controller = TweetFeedController();
      addTearDown(controller.dispose);

      controller.applyFirstPage(page(['1', '2'], 'c1'));
      controller.applyFirstPage(page(['0'], 'c0'));

      expect(controller.items?.map((chain) => chain.id), ['0'],
          reason: 'The ranked feed reshuffles on refresh, so its page should replace what was '
              'shown instead of piling up old ranks');
    });
  });

  group('TweetFeedController paging', () {
    test('Should drop the tweets already on screen from later pages', () async {
      final controller = TweetFeedController();
      addTearDown(controller.dispose);
      final pages = [
        page(['1', '2'], 'c1'),
        page(['2', '3'], 'c2'),
      ];
      var fetched = 0;
      controller.loader = (cursor) async => pages[fetched++];

      controller.controller.fetchNextPage();
      await pumpEventQueue();
      controller.controller.fetchNextPage();
      await pumpEventQueue();

      expect(controller.items?.map((chain) => chain.id), ['1', '2', '3'],
          reason: 'Ranked feeds can repeat a tweet across pages, and a repeated chain would '
              'render twice');
      expect(controller.controller.value.hasNextPage, isTrue,
          reason: 'An all-duplicate page should still keep pagination alive instead of looking '
              'like the end of the feed');
    });
  });
}
