import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/tweet/paginated_tweet_list.dart';
import 'package:quax/utils/network_status.dart';

TweetChain chain(String id) =>
    TweetChain(id: id, tweets: const [], isPinned: false);

void main() {
  testWidgets(
    'Should not surface a refresh error from a feed generation that was reset',
    (tester) async {
      final oldFeed = TweetFeedController();
      final newFeed = TweetFeedController();
      addTearDown(oldFeed.dispose);
      addTearDown(newFeed.dispose);
      final network = NetworkStatus.withProbe(() async => true);
      addTearDown(network.dispose);
      final refresh = Completer<TweetPageResult>();
      var requested = false;
      Future<TweetPageResult> oldLoader(String? _) {
        requested = true;
        return refresh.future;
      }

      Future<TweetPageResult> newLoader(String? _) async =>
          (chains: [chain('new-page')], nextCursor: null);
      oldFeed.loader = oldLoader;
      newFeed.loader = newLoader;
      oldFeed.applyFirstPage((
        chains: [chain('old-account')],
        nextCursor: 'old-next',
      ));
      newFeed.applyFirstPage((
        chains: [chain('new-account')],
        nextCursor: null,
      ));

      Widget build(TweetFeedController feed, TweetPageLoader loader) =>
          MaterialApp(
            localizationsDelegates: const [
              L10n.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            supportedLocales: L10n.delegate.supportedLocales,
            home: Provider<NetworkStatus>.value(
              value: network,
              child: PrefService(
                service: PrefServiceCache(cache: {}),
                child: PaginatedTweetList(
                  feed: feed,
                  loadPage: loader,
                  username: null,
                  onRefresh: () async {},
                  firstPageErrorPrefix: '',
                  newPageErrorPrefix: '',
                  emptyMessage: '',
                ),
              ),
            ),
          );

      await tester.pumpWidget(build(oldFeed, oldLoader));

      final indicator = tester.state<RefreshIndicatorState>(
        find.byType(RefreshIndicator),
      );
      final showing = indicator.show();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        requested,
        isTrue,
        reason: 'The stale request must actually be in flight before reset',
      );

      oldFeed.reset();
      await tester.pumpWidget(build(newFeed, newLoader));
      refresh.completeError(StateError('old account failed'));
      await showing;
      await tester.pump();

      expect(
        newFeed.controller.value.error,
        isNull,
        reason:
            'A failed request for the previous account must not replace the new feed with '
            'an error screen or its snackbar',
      );
      expect(newFeed.items?.map((item) => item.id), [
        'new-account',
      ], reason: 'The replacement feed keeps its own loaded page');
      expect(
        find.textContaining('old account failed'),
        findsNothing,
        reason: 'The reader switched feeds; an error from the abandoned request is not actionable',
      );
    },
  );
}
