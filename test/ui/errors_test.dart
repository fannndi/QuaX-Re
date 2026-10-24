import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/ui/errors.dart';

void main() {
  // The tombstone/error text falls back to translated strings.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await L10n.load(const Locale('en'));
  });

  group('createEmojiError()', () {
    TwitterError errorWith(int code) => TwitterError(code: code, message: 'raw', uri: 'https://x.com/');

    test('Should name the reason for each code X is known to send', () {
      // These are the only places the reader learns *why* a request failed.
      // A code that falls through to "catastrophic failure" tells them nothing
      // and sends them looking for a bug that is not theirs.
      final reasons = {
        22: L10n.current.private_profile,
        34: L10n.current.page_not_found,
        50: L10n.current.user_not_found,
        63: L10n.current.account_suspended,
        200: L10n.current.forbidden,
        239: L10n.current.bad_guest_token,
      };

      reasons.forEach((code, expected) {
        expect(createEmojiError(errorWith(code)).message, expected,
            reason: 'X answered with code $code, so that is what the reader should be told');
      });
    });

    test('Should fall back to the generic message for an unknown code', () {
      expect(createEmojiError(errorWith(9999)).message, L10n.current.catastrophic_failure,
          reason: 'A code this build has never seen must still render something, rather than '
              'throw inside the error path');
    });

    test('Should give every code an emoji, so no failure renders blank', () {
      for (final code in const [22, 34, 50, 63, 200, 239, 9999]) {
        expect(createEmojiError(errorWith(code)).emoji, isNotEmpty,
            reason: 'Code $code would render an error widget with no icon at all');
      }
    });
  });
}
