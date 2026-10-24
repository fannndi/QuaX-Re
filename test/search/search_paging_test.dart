import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/client.dart';
import 'package:quax/search/search_model.dart';

TweetChain chain(String id) => TweetChain(id: id, tweets: const [], isPinned: false);

void main() {
  group('nextCursorOrEnd()', () {
    test('Should keep paging while the cursor advances', () {
      expect(nextCursorOrEnd([chain('1')], 'cursor-b', 'cursor-a'), 'cursor-b',
          reason: 'A page with items and a fresh cursor is a normal page, so pagination continues');
    });

    test('Should end on a cursor that did not advance, which is the loop X serves', () {
      expect(nextCursorOrEnd([chain('1')], 'cursor-a', 'cursor-a'), isNull,
          reason: 'X answers with the same bottom cursor twice when a query runs out of results; '
              'paging on it would request the same page forever, each request burning a rate-limit '
              'slot and coming back all duplicates');
    });

    test('Should end on an empty page even when a cursor came back', () {
      expect(nextCursorOrEnd(const [], 'cursor-b', 'cursor-a'), isNull,
          reason: 'An empty page means there is nothing left to show, so the cursor it carries '
              'must not be followed');
    });

    test('Should end on a missing or blank cursor', () {
      expect(nextCursorOrEnd([chain('1')], null, 'cursor-a'), isNull,
          reason: 'No cursor means X has nothing more to offer');
      expect(nextCursorOrEnd([chain('1')], '', 'cursor-a'), isNull,
          reason: 'A blank cursor is not a cursor, and paging on it would request the first page '
              'again');
    });

    test('Should end on the first page when it is empty and cursorless', () {
      expect(nextCursorOrEnd(const [], null, null), isNull,
          reason: 'A query with no results at all must end pagination immediately rather than '
              'retrying the same first page');
    });
  });
}
