import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/ui/errors.dart';

void main() {
  // The tombstone/error text falls back to translated strings.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await L10n.load(const Locale('en'));
  });

  testWidgets('Should not offer Back on an inline content warning', (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [L10n.delegate, ...GlobalMaterialLocalizations.delegates],
      supportedLocales: L10n.delegate.supportedLocales,
      home: Scaffold(
        body: EmojiErrorWidget(
          emoji: '🙈',
          message: 'hidden',
          errorMessage: 'sensitive',
          retryText: 'show',
          showBackButton: false,
          onRetry: () {},
        ),
      ),
    ));

    expect(find.text(L10n.current.back), findsNothing,
        reason: 'The Back button belonged to the feed route, not to this card; on the home tab '
            'it used to close the app instead of revealing the post');
    expect(find.text('show'), findsOneWidget,
        reason: 'The only action on a content warning is the reveal action');
  });

  testWidgets('Should keep the raw exception and stack trace off the error page', (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [L10n.delegate, ...GlobalMaterialLocalizations.delegates],
      supportedLocales: L10n.delegate.supportedLocales,
      home: Scaffold(
        body: FullPageErrorWidget(
          error: StateError('internal-path/secret'),
          stackTrace: StackTrace.current,
          prefix: 'Could not load',
        ),
      ),
    ));

    expect(find.textContaining('internal-path/secret'), findsNothing,
        reason: 'The reader cannot act on a Dart exception, and the text exposed internal paths');
    expect(find.text(L10n.current.copy_details), findsOneWidget,
        reason: 'The details are still available for a bug report, one tap away');
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
