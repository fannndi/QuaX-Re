import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:quax/client/client.dart';
import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/likes/liked_tweet_model.dart';
import 'package:quax/tweet/tweet.dart';
import 'package:quax/user.dart';

class _PendingLikeModel extends LikedTweetModel {
  final pending = Completer<bool>();
  int calls = 0;

  @override
  bool isLiked(String id) => false;

  @override
  Future<bool> likeTweet(
    String id,
    String? user,
    Map<String, dynamic> content,
  ) {
    calls++;
    return pending.future;
  }
}

TweetWithCard post() => TweetWithCard()
  ..idStr = '1'
  ..text = 'hello'
  ..favoriteCount = 0
  ..user = (UserWithExtra()
    ..idStr = 'author'
    ..name = 'Author'
    ..screenName = 'author');

void main() {
  testWidgets(
    'Should block duplicate like taps and explain a false mutation result',
    (tester) async {
      final model = _PendingLikeModel();
      addTearDown(model.destroy);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            L10n.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: L10n.delegate.supportedLocales,
          home: PrefService(
            service: PrefServiceCache(
              cache: {
                optionNonConfirmationBiasMode: false,
                alwaysShowFullTweetContents: false,
              },
            ),
            child: Provider<LikedTweetModel>.value(
              value: model,
              child: Scaffold(body: TweetTile(clickable: true, tweet: post())),
            ),
          ),
        ),
      );

      final heart = find.byIcon(Icons.favorite_border);
      await tester.tap(heart);
      await tester.pump();

      expect(
        model.calls,
        1,
        reason: 'The first tap starts exactly one local like write',
      );
      final button = tester.widget<TextButton>(
        find.ancestor(of: heart, matching: find.byType(TextButton)),
      );
      expect(
        button.onPressed,
        isNull,
        reason: 'The heart must be disabled while the database mutation is in flight',
      );

      await tester.tap(heart, warnIfMissed: false);
      expect(
        model.calls,
        1,
        reason: 'A second tap must not queue a duplicate write',
      );

      model.pending.complete(false);
      await tester.pumpAndSettle();

      expect(
        find.text(L10n.current.no_account_available_message),
        findsOneWidget,
        reason:
            'A false result means the write did not happen; the reader needs actionable '
            'no-account feedback instead of a success animation',
      );
      final retriedButton = tester.widget<TextButton>(
        find.ancestor(of: heart, matching: find.byType(TextButton)),
      );
      expect(
        retriedButton.onPressed,
        isNotNull,
        reason: 'After the mutation settles the reader can try again',
      );
    },
  );
}
