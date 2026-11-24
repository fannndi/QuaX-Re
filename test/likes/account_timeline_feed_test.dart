import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:quax/client/client.dart';
import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/likes/likes_screen.dart';
import 'package:quax/profile/_feed.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/user.dart';

UserWithExtra account(String id, String handle) => UserWithExtra.fromArguments(
  idStr: id,
  screenName: handle,
  name: handle,
  possiblySensitive: true,
);

Widget harness(
  TweetContextState context,
  UserWithExtra user,
  String endpoint,
) => MaterialApp(
  localizationsDelegates: const [
    L10n.delegate,
    ...GlobalMaterialLocalizations.delegates,
  ],
  supportedLocales: L10n.delegate.supportedLocales,
  home: PrefService(
    service: PrefServiceCache(cache: {optionTweetsHideSensitive: true}),
    child: ChangeNotifierProvider.value(
      value: context,
      child: AccountTimelineFeed(
        user: user,
        endpoint: endpoint,
        emptyMessage: '',
        loadPage: (_, _, _, _) async =>
            TweetStatus(chains: const [], cursorBottom: null, cursorTop: null),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'Should recreate account timeline paging when the account or endpoint changes',
    (tester) async {
      final context = TweetContextState(true);
      addTearDown(context.dispose);
      final accountA = account('100', 'account_a');
      final accountB = account('200', 'account_b');

      await tester.pumpWidget(harness(context, accountA, 'likes'));
      final firstWidget = tester.widget<ProfileTweetFeed>(
        find.byType(ProfileTweetFeed),
      );
      final firstState = tester.state(find.byType(ProfileTweetFeed));

      await tester.pumpWidget(harness(context, accountB, 'likes'));
      final secondWidget = tester.widget<ProfileTweetFeed>(
        find.byType(ProfileTweetFeed),
      );
      final secondState = tester.state(find.byType(ProfileTweetFeed));

      expect(
        firstWidget.key,
        isNot(secondWidget.key),
        reason: 'A different numeric account id must not reuse the previous account\'s pager',
      );
      expect(
        identical(firstState, secondState),
        isFalse,
        reason: 'Reusing the State would carry account A\'s items, cursor and seen ids into B',
      );

      await tester.pumpWidget(harness(context, accountB, 'bookmarks'));
      final endpointWidget = tester.widget<ProfileTweetFeed>(
        find.byType(ProfileTweetFeed),
      );
      final endpointState = tester.state(find.byType(ProfileTweetFeed));

      expect(
        endpointWidget.key,
        isNot(secondWidget.key),
        reason:
            'Likes and bookmarks are different private endpoint result sets',
      );
      expect(
        identical(secondState, endpointState),
        isFalse,
        reason:
            'Changing endpoint kind must also create a fresh paging controller',
      );
    },
  );
}
