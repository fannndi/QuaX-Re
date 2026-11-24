import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/client.dart';

void main() {
  test(
    'Should read a bottom cursor from a replace entry regardless of case',
    () {
      final cursor = getCursor(
        [],
        [
          {
            'replaceEntry': {
              'entryIdToReplace': 'cursor-bottom-123',
              'entry': {
                'content': {
                  'operation': {
                    'cursor': {'cursorType': 'Bottom', 'value': 'abc'},
                  },
                },
              },
            },
          },
        ],
        'cursor-bottom',
        'Bottom',
      );

      expect(
        cursor,
        'abc',
        reason:
            'The replace-entry id is lowercase while callers pass "Bottom"; the case-sensitive '
            'contains() missed it and pagination stopped after the first page',
      );
    },
  );

  test(
    'Should read a follows cursor when only replace entries are present',
    () {
      final users = parseFollows({
        'data': {
          'user': {
            'result': {
              'timeline': {
                'timeline': {
                  'instructions': [
                    {
                      'type': 'TimelineReplaceEntry',
                      'replaceEntry': {
                        'entryIdToReplace': 'cursor-bottom-1',
                        'entry': {
                          'content': {
                            'operation': {
                              'cursor': {
                                'cursorType': 'Bottom',
                                'value': 'replace-only',
                              },
                            },
                          },
                        },
                      },
                    },
                  ],
                },
              },
            },
          },
        },
      });

      expect(
        users.users,
        isEmpty,
        reason: 'A replace-only page can legitimately contain no user entries',
      );
      expect(
        users.nextCursorStr,
        'replace-only',
        reason: 'Follow pagination must not depend on an AddEntries instruction being present',
      );
    },
  );

  test(
    'Should fall back to a replace cursor when only the other cursor was added',
    () {
      final cursor = getCursor(
        [
          {
            'entryId': 'cursor-top-1',
            'content': {'cursorType': 'Top', 'value': 'top'},
          },
        ],
        [
          {
            'replaceEntry': {
              'entryIdToReplace': 'cursor-bottom-1',
              'entry': {
                'content': {
                  'operation': {
                    'cursor': {'cursorType': 'Bottom', 'value': 'bottom'},
                  },
                },
              },
            },
          },
        ],
        'cursor-bottom',
        'Bottom',
      );

      expect(
        cursor,
        'bottom',
        reason:
            'Finding some cursor entry must not suppress the replace-entry fallback for a '
            'different cursor direction',
      );
    },
  );

  test('Should return null when there is no cursor entry', () {
    expect(
      getCursor([], [], 'cursor-bottom', 'Bottom'),
      isNull,
      reason: 'A page without a cursor is the end of the feed, not an error',
    );
  });

  test('Should read the follows bottom cursor from a replace entry', () {
    final users = parseFollows({
      'data': {
        'user': {
          'result': {
            'timeline': {
              'timeline': {
                'instructions': [
                  {
                    'type': 'TimelineAddEntries',
                    'entries': [
                      {
                        'content': {
                          'itemContent': {
                            'user_results': {
                              'result': {
                                'rest_id': '1',
                                'core': {
                                  'screen_name': 'alice',
                                  'name': 'Alice',
                                },
                              },
                            },
                          },
                        },
                      },
                    ],
                  },
                  {
                    'type': 'TimelineReplaceEntry',
                    'replaceEntry': {
                      'entryIdToReplace': 'cursor-bottom-1',
                      'entry': {
                        'content': {
                          'operation': {
                            'cursor': {
                              'cursorType': 'Bottom',
                              'value': 'next-page',
                            },
                          },
                        },
                      },
                    },
                  },
                ],
              },
            },
          },
        },
      },
    });

    expect(
      users.users?.single.screenName,
      'alice',
      reason: 'The populated follows page should keep the user it parsed',
    );
    expect(
      users.nextCursorStr,
      'next-page',
      reason:
          'A replace-entry bottom cursor is the only way to reach the rest of the list; '
          'dropping it stopped Following at the first page',
    );
  });
}
