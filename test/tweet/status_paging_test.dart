import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/client.dart';
import 'package:quax/status.dart';

TweetChain chain(String id) =>
    TweetChain(id: id, tweets: const [], isPinned: false);

TweetStatus status(List<String> ids, String? cursor) => TweetStatus(
  chains: ids.map(chain).toList(),
  cursorBottom: cursor,
  cursorTop: null,
);

void main() {
  group('StatusPageAccumulator', () {
    test('Should filter duplicates anywhere in an overlapping page', () {
      final pages = StatusPageAccumulator();

      pages.add(status(['a', 'b'], 'cursor-1'), null);
      final second = pages.add(
        status(['b', 'c', 'b', 'd'], 'cursor-2'),
        'cursor-1',
      );

      expect(
        second.items.map((item) => item.id),
        ['c', 'd'],
        reason:
            'skipWhile stopped at the first fresh reply and let every later duplicate '
            'through; the whole page must be checked against the seen set',
      );
      expect(
        second.nextCursor,
        'cursor-2',
        reason:
            'Fresh replies and an advancing cursor mean there is another page',
      );
    });

    test(
      'Should keep paginating after an all-duplicate page with a new cursor',
      () {
        final pages = StatusPageAccumulator();
        pages.add(status(['a', 'b'], 'cursor-1'), null);

        final duplicates = pages.add(
          status(['b', 'a'], 'cursor-2'),
          'cursor-1',
        );
        final fresh = pages.add(status(['c'], null), 'cursor-2');

        expect(
          duplicates.items,
          isEmpty,
          reason: 'Every chain on this page is already visible',
        );
        expect(
          duplicates.nextCursor,
          'cursor-2',
          reason:
              'The raw page was non-empty and its cursor advanced, so ending here would '
              'hide replies that only appear on the following page',
        );
        expect(
          fresh.items.map((item) => item.id),
          ['c'],
          reason: 'Pagination must reach the later page instead of stopping at duplicates',
        );
      },
    );

    test('Should end on an empty page or a cursor that did not advance', () {
      final pages = StatusPageAccumulator();
      pages.add(status(['a'], 'cursor-1'), null);

      expect(
        pages.add(status([], 'cursor-2'), 'cursor-1').nextCursor,
        isNull,
        reason: 'An empty raw page has nothing more to offer',
      );
      expect(
        pages.add(status(['b'], 'cursor-1'), 'cursor-1').nextCursor,
        isNull,
        reason: 'Requesting the same cursor forever would burn rate limit without progress',
      );
    });
  });
}
