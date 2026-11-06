import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/client.dart';

void main() {
  test('Should read a bottom cursor from a replace entry regardless of case', () {
    final cursor = getCursor([], [
      {
        'replaceEntry': {
          'entryIdToReplace': 'cursor-bottom-123',
          'entry': {
            'content': {
              'operation': {
                'cursor': {'cursorType': 'Bottom', 'value': 'abc'}
              }
            }
          }
        }
      }
    ], 'cursor-bottom', 'Bottom');

    expect(cursor, 'abc',
        reason: 'The replace-entry id is lowercase while callers pass "Bottom"; the case-sensitive '
            'contains() missed it and pagination stopped after the first page');
  });

  test('Should return null when there is no cursor entry', () {
    expect(getCursor([], [], 'cursor-bottom', 'Bottom'), isNull,
        reason: 'A page without a cursor is the end of the feed, not an error');
  });
}
