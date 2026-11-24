import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:quax/client/client.dart';
import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/tweet/paginated_tweet_list.dart';
import 'package:quax/utils/network_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

TweetChain chain(int id) => TweetChain(
  id: '$id',
  isPinned: false,
  tweets: [
    TweetWithCard()
      ..idStr = '$id'
      ..isTombstone = true
      ..text = 'Unavailable post $id',
  ],
);

void main() {
  testWidgets(
    'Should load the saved number of pages before restoring a deep scroll offset',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'scroll.test-feed': 900.0,
        'scroll.test-feed.at': DateTime.now().millisecondsSinceEpoch,
        'scroll.test-feed.pages': 3,
      });
      final prefs = await PrefServiceShared.init(
        defaults: {
          optionNonConfirmationBiasMode: false,
          alwaysShowFullTweetContents: false,
        },
      );
      final network = NetworkStatus.withProbe(() async => true);
      addTearDown(network.dispose);
      final feed = TweetFeedController();
      addTearDown(feed.dispose);
      final cursors = <String?>[];
      var page = 1;
      late TweetPageLoader loader;
      loader = (cursor) async {
        cursors.add(cursor);
        final ids = List.generate(10, (index) => page * 10 + index);
        page++;
        return (
          chains: ids.map(chain).toList(),
          nextCursor: page == 3 ? null : 'cursor-$page',
        );
      };
      feed.loader = loader;
      feed.applyFirstPage((
        chains: List.generate(10, (index) => chain(index)).toList(),
        nextCursor: 'cursor-1',
      ));

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            L10n.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: L10n.delegate.supportedLocales,
          home: PrefService(
            service: prefs,
            child: Provider<NetworkStatus>.value(
              value: network,
              child: SizedBox(
                width: 400,
                height: 600,
                child: PaginatedTweetList(
                  feed: feed,
                  loadPage: loader,
                  username: null,
                  firstPageErrorPrefix: '',
                  newPageErrorPrefix: '',
                  emptyMessage: '',
                  scrollKey: 'test-feed',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        cursors,
        ['cursor-1', 'cursor-2'],
        reason:
            'The saved position was three pages deep, so restore must fetch pages two and '
            'three instead of clamping to the first page',
      );
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(
        position.pixels,
        closeTo(900, 1),
        reason: 'Once enough content is loaded, the reader returns to the exact saved offset',
      );
    },
  );
}
