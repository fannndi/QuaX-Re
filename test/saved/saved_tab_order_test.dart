import 'package:flutter_test/flutter_test.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/saved/saved_tab_order.dart';

void main() {
  SavedTweetFolder folder(String id, String name) =>
      SavedTweetFolder(id: id, name: name, createdAt: DateTime(2026, 1, 1));

  group('orderedSavedTabs()', () {
    test('Should list the built-in tabs around the folders by default', () {
      final tabs = orderedSavedTabs([folder('a', 'A'), folder('b', 'B')], null);

      expect(tabs, [savedTabAll, 'a', 'b', savedTabUnfiled, savedTabFavorites],
          reason: 'Without a custom order the folders sit between All and the built-in Unfiled and '
              'Likes tabs, mirroring the order they were created in');
    });

    test('Should honour the stored order', () {
      final tabs = orderedSavedTabs([folder('a', 'A'), folder('b', 'B')], '["b","a"]');

      expect(tabs, ['b', 'a', savedTabAll, savedTabUnfiled, savedTabFavorites],
          reason: 'Dragging a tab in Manage folders writes this order, so reopening the Saved tab '
              'should show the same arrangement');
    });

    test('Should drop the tokens of folders that no longer exist', () {
      final tabs = orderedSavedTabs([folder('a', 'A')], '["b","a"]');

      expect(tabs, ['a', savedTabAll, savedTabUnfiled, savedTabFavorites],
          reason: 'A deleted folder leaves its token in the stored order, but a token without a '
              'folder would make the strip crash on a missing name');
    });

    test('Should append tabs missing from the stored order', () {
      final tabs = orderedSavedTabs([folder('new', 'New')], '["$savedTabAll"]');

      expect(tabs, [savedTabAll, 'new', savedTabUnfiled, savedTabFavorites],
          reason: 'A folder created after the order was stored is not in it yet, so it should be '
              'appended rather than hidden from the strip');
    });

    test('Should fall back to the default order when the stored order is not valid JSON', () {
      final tabs = orderedSavedTabs([folder('a', 'A')], 'not json at all');

      expect(tabs, [savedTabAll, 'a', savedTabUnfiled, savedTabFavorites],
          reason: 'A corrupted preference should never break the Saved tab, it should just lose '
              'the custom arrangement');
    });

    test('Should not duplicate a token that is both stored and missing from the defaults', () {
      final tabs = orderedSavedTabs([folder('a', 'A')], '["$savedTabUnfiled"]');

      expect(tabs.where((t) => t == savedTabUnfiled).length, 1,
          reason: 'The stored Unfiled token is prepended, so the default pass should not add it a '
              'second time and give the strip two identical chips');
    });
  });
}
