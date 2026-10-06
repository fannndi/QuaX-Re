import 'package:flutter_test/flutter_test.dart';
import 'package:quax/home/_feed.dart';
import 'package:quax/home/home_screen.dart';

/// The navigation is the fork's most visible difference from upstream, and the
/// one the documentation got wrong most easily: an extra or reordered tab
/// changes where the reader lands, what they can reach and what the persisted
/// "start on this tab" key has to say.
void main() {
  group('defaultHomePages', () {
    test('Should keep exactly three tabs in the fork\'s order', () {
      expect(defaultHomePages.map((page) => page.id).toList(), ['downloads', 'feed', 'likes'],
          reason: 'The app is meant to stay three tabs wide, with Download first and Like last; '
              'an added or reordered tab moves every reader\'s muscle memory and the scroll keys '
              'stored against each position');
    });

    test('Should keep Home centred between the other two', () {
      expect(defaultHomePages[1].id, 'feed',
          reason: 'Home sits in the middle like a home button — the comment in home_screen.dart '
              'and the on-screen layout both promise it, and a reorder would silently break that');
    });

    test('Should carry a distinct id for each tab', () {
      final ids = defaultHomePages.map((page) => page.id).toSet();

      expect(ids, hasLength(defaultHomePages.length),
          reason: 'The navigation reads and writes its position by id (the starting tab, the '
              'per-tab scroll key), so two tabs sharing one would collide');
    });

    test('Should give every tab both an idle and a selected icon', () {
      for (final page in defaultHomePages) {
        expect(page.icon, isNotNull,
            reason: 'A tab with no icon would render as bare text in a bar that shows icons');
        expect(page.selectedIcon, isNotNull,
            reason: 'The bar swaps to the selected icon, so missing it would leave the tab blank '
                'when it is the active one');
      }
    });
  });

  group('feedTabs', () {
    test('Should offer For You and Following, in that order', () {
      expect(feedTabs.map((tab) => tab.id).toList(), [FeedTab.foryou, FeedTab.following],
          reason: 'The home bar builds its tabs from this list and the reader taps them left to '
              'right; changing it changes what the first tab is');
    });
  });

  group('feedTabFromId', () {
    test('Should read back every feed the settings can store', () {
      expect(feedTabFromId('foryou'), FeedTab.foryou,
          reason: 'The stored preference round-trips: what was written has to come back as the '
              'same tab, or the home feed opens on the other one');
      expect(feedTabFromId('following'), FeedTab.following, reason: 'Same, for the second tab');
    });

    test('Should fall back to For You for anything it does not know', () {
      expect(feedTabFromId('nonsense'), FeedTab.foryou,
          reason: 'A value left behind by an older build must not crash the feed or open a tab '
              'that does not exist');
      expect(feedTabFromId(null), FeedTab.foryou,
          reason: 'First launch has no stored tab at all, and the feed still has to open');
    });
  });
}
