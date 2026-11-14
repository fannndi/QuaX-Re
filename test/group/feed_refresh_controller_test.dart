import 'package:flutter_test/flutter_test.dart';
import 'package:quax/group/feed_refresh_controller.dart';

void main() {
  group('FeedRefreshController', () {
    test('Should refresh and scroll only the active feed', () async {
      final controller = FeedRefreshController();
      var forYou = 0;
      var following = 0;

      controller.register('foryou', refresh: () async => forYou++, scrollToTop: () => forYou++);
      controller.register('following',
          refresh: () async => following++, scrollToTop: () => following++);

      controller.activeFeedId = 'following';
      await controller.refresh();
      controller.scrollToTop();

      expect(following, 2,
          reason: 'The app-bar refresh and the nav scroll must reach the feed the reader is on');
      expect(forYou, 0,
          reason: 'The hidden feed used to win the single registration slot, so the visible tab '
              'showed no spinner and no new posts');
    });

    test('Should do nothing when the active feed has no handler', () async {
      final controller = FeedRefreshController();
      controller.activeFeedId = 'missing';

      await expectLater(controller.refresh(), completes);
      expect(() => controller.scrollToTop(), returnsNormally,
          reason: 'A feed that has not mounted yet (or one without pull-to-refresh) must not crash '
              'the app-bar button');
    });

    test('Should stop reaching a feed that unregistered', () async {
      final controller = FeedRefreshController();
      var scrolled = 0;

      final token = controller.register('foryou', refresh: () async {}, scrollToTop: () => scrolled++);
      controller.activeFeedId = 'foryou';
      controller.unregister('foryou', token);
      controller.scrollToTop();

      expect(scrolled, 0,
          reason: 'A disposed feed must not be scrolled, or the tap acts on a list that is gone');
    });

    test('Should keep the new feed when the old one is disposed after a switch', () async {
      final controller = FeedRefreshController();
      var scrolled = 0;

      final oldToken = controller.register('foryou', refresh: () async {}, scrollToTop: () {});
      controller.register('foryou', refresh: () async {}, scrollToTop: () => scrolled++);
      controller.activeFeedId = 'foryou';
      // Flutter mounts the replacement before it disposes the old subtree.
      controller.unregister('foryou', oldToken);
      controller.scrollToTop();

      expect(scrolled, 1,
          reason: 'The old dispose used to remove the new handler by key alone, so the app-bar '
              'refresh and the nav scroll did nothing after every account switch');
    });

    test('Should keep both home feeds registered at once', () {
      final controller = FeedRefreshController();
      controller.register('foryou', refresh: () async {}, scrollToTop: () {});
      controller.register('following', refresh: () async {}, scrollToTop: () {});

      expect(controller.handlerCount, 2,
          reason: 'For You and Following stay alive together; one slot let the last-mounted one '
              'silently replace the other');
    });
  });
}
