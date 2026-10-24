import 'package:flutter_test/flutter_test.dart';
import 'package:quax/group/feed_refresh_controller.dart';

void main() {
  group('FeedRefreshController.scrollToTop()', () {
    test('Should reach the scroll-to-top the feed body registered', () {
      final controller = FeedRefreshController();
      var scrolled = 0;

      controller.registerScrollToTop(() => scrolled++);
      controller.scrollToTop();

      expect(scrolled, 1,
          reason: 'Tapping the active nav tab has to scroll the feed list itself. The nav bar can '
              'only reach the NestedScrollView outer controller, which collapses the app bar and '
              'leaves the reader exactly where they were');
    });

    test('Should do nothing when no body registered one', () {
      final controller = FeedRefreshController();

      expect(() => controller.scrollToTop(), returnsNormally,
          reason: 'A feed without pull-to-refresh (or one that has not mounted yet) has nothing to '
              'scroll, and the nav bar must not crash on it');
    });

    test('Should stop reaching a body that unregistered', () {
      final controller = FeedRefreshController();
      var scrolled = 0;
      void handler() => scrolled++;

      controller.registerScrollToTop(handler);
      controller.unregisterScrollToTop(handler);
      controller.scrollToTop();

      expect(scrolled, 0,
          reason: 'A disposed feed must not be scrolled any more, or the tap would act on a list '
              'that is no longer on screen');
    });

    test('Should not unregister a newer body when an older one goes away', () {
      final controller = FeedRefreshController();
      var first = 0;
      var second = 0;

      controller.registerScrollToTop(() => first++);
      controller.registerScrollToTop(() => second++);
      controller.unregisterScrollToTop(() => first++);
      controller.scrollToTop();

      expect(first, 0, reason: 'The stale handler is gone');
      expect(second, 1,
          reason: 'Only the handler that is actually registered may be removed; removing by value '
              'would let a stale callback wipe the live one');
    });
  });
}
