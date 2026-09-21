import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/client.dart';
import 'package:quax/tweet/paginated_tweet_list.dart';

TweetChain chain(String id) => TweetChain(id: id, tweets: const [], isPinned: false);

void main() {
  group('TweetFeedController.reset()', () {
    test('Should clear what is loaded so the next page is the first one', () async {
      final feed = TweetFeedController();
      final cursors = <String?>[];
      feed.loader = (cursor) {
        cursors.add(cursor);
        return Future.value((chains: [chain('a')], nextCursor: 'next'));
      };

      feed.controller.fetchNextPage();
      await pumpEventQueue();
      expect(feed.items?.map((item) => item.id), ['a'],
          reason: 'The feed has to load normally first, otherwise the reset below proves nothing');

      feed.reset();
      expect(feed.hasItems, isFalse,
          reason: 'An account switch must not leave the previous login\'s posts on screen, '
              'not even for the frame before the new first page arrives');

      feed.controller.fetchNextPage();
      await pumpEventQueue();
      expect(cursors, [null, null],
          reason: 'After a reset the feed has to start over from the first page instead of '
              'resuming the old account\'s cursor');
      expect(feed.items?.map((item) => item.id), ['a'],
          reason: 'The fresh first page replaces the discarded one');

      feed.dispose();
    });

    test('Should drop a page that lands after a reset', () async {
      final feed = TweetFeedController();
      final inFlight = Completer<TweetPageResult>();
      final cursors = <String?>[];
      var firstPages = 0;

      feed.loader = (cursor) {
        cursors.add(cursor);
        if (cursor == null) {
          firstPages++;
          return Future.value(firstPages == 1
              ? (chains: [chain('old-page-1')], nextCursor: 'old-next')
              : (chains: [chain('fresh-page-1')], nextCursor: 'fresh-next'));
        }
        return switch (cursor) {
          'old-next' => inFlight.future,
          _ => Future.value((chains: [chain('fresh-next-page')], nextCursor: null)),
        };
      };

      feed.controller.fetchNextPage();
      await pumpEventQueue();
      feed.controller.fetchNextPage();
      await pumpEventQueue();

      // The reader switches accounts while the next page is still on its way.
      feed.reset();
      feed.controller.fetchNextPage();
      await pumpEventQueue();

      inFlight.complete((chains: [chain('old-account-page')], nextCursor: 'stale-cursor'));
      await pumpEventQueue();

      expect(feed.items?.map((item) => item.id), ['fresh-page-1'],
          reason: 'A response that was requested with the previous account must never be '
              'appended to the new one\'s list, that is exactly how two timelines end up mixed');
      expect(cursors, [null, 'old-next', null],
          reason: 'The dropped page must not hand its cursor over either, otherwise the next '
              'scroll would ask the new account for the old one\'s page two');

      feed.controller.fetchNextPage();
      await pumpEventQueue();
      expect(feed.items?.map((item) => item.id), ['fresh-page-1', 'fresh-next-page'],
          reason: 'Pagination continues from the new account\'s cursor');

      feed.dispose();
    });

    test('Should drop a page that lands after the first page was replaced', () async {
      final feed = TweetFeedController();
      final inFlight = Completer<TweetPageResult>();
      final cursors = <String?>[];
      feed.loader = (cursor) {
        cursors.add(cursor);
        return switch (cursor) {
          null => Future.value((chains: [chain('page-1')], nextCursor: 'next')),
          'next' => inFlight.future,
          _ => Future.value((chains: [chain('refreshed-next')], nextCursor: null)),
        };
      };

      feed.controller.fetchNextPage();
      await pumpEventQueue();
      feed.controller.fetchNextPage();
      await pumpEventQueue();

      // Pull-to-refresh while the next page is still on its way: the refresh
      // starts a new cursor chain, so the pending page belongs to the old one.
      feed.applyFirstPage((chains: [chain('refreshed')], nextCursor: 'fresh'));
      inFlight.complete((chains: [chain('stale-page')], nextCursor: 'stale-cursor'));
      await pumpEventQueue();

      expect(feed.items?.map((item) => item.id), ['refreshed'],
          reason: 'A slow page from before the refresh must not reappear below the refreshed '
              'posts, they would read as older posts that are not in the timeline');

      feed.controller.fetchNextPage();
      await pumpEventQueue();
      expect(cursors.last, 'fresh',
          reason: 'Pagination has to continue from the refreshed cursor chain');
      expect(feed.items?.map((item) => item.id), ['refreshed', 'refreshed-next'],
          reason: 'The page after the refresh loads and appends normally');

      feed.dispose();
    });
  });
}
