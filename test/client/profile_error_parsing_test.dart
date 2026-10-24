import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await L10n.load(const Locale('en'));
  });

  group('parseProfile() error bodies', () {
    TwitterError errorOf(Map<String, dynamic> body) {
      try {
        parseProfile(body, 'https://x.com/i/api/graphql/x/UserByScreenName');
      } on TwitterError catch (e) {
        return e;
      }
      fail('An error body must throw a TwitterError, not fall through to the success path');
    }

    test('Should read the code and message X sent', () {
      final error = errorOf({
        'errors': [
          {'code': 63, 'message': 'Suspended'}
        ]
      });

      expect(error.code, 63,
          reason: 'createEmojiError maps this code to "account suspended"; losing it leaves the '
              'reader with a generic failure and no reason');
      expect(error.message, 'Suspended', reason: 'The message X gave is the most specific thing we have');
    });

    test('Should survive a code that is not an int', () {
      // X documents errors[].code as an int but does not guarantee it. Reading it
      // with `as int` throws a TypeError inside the parse isolate, which surfaces
      // as an unhandled async error rather than a TwitterError the error widget
      // can map.
      final error = errorOf({
        'errors': [
          {'code': '63', 'message': 'Suspended'}
        ]
      });

      expect(error.code, 63,
          reason: 'A stringified code is still the code, and the reader should still be told the '
              'account is suspended');
    });

    test('Should fall back rather than throw when the shape moved', () {
      for (final body in <Map<String, dynamic>>[
        {
          'errors': ['not a map']
        },
        {
          'errors': [
            {'code': 63}
          ]
        },
        {
          'errors': [
            {'message': 'no code at all'}
          ]
        },
        {
          'errors': [
            {'code': null, 'message': null}
          ]
        },
      ]) {
        final error = errorOf(body);
        expect(error.message, isNotNull,
            reason: 'A reshaped error body must still produce a message, so the error widget '
                'renders instead of the isolate throwing: $body');
      }
    });
  });
}
