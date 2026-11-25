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

class _LikedIdsModel extends LikedTweetModel {
  _LikedIdsModel(this.ids);

  final Set<String> ids;

  @override
  bool isLiked(String id) => ids.contains(id);
}

TweetWithCard post({
  String id = '1',
  bool favorited = false,
  bool bookmarked = false,
}) => TweetWithCard()
  ..idStr = id
  ..fullText = 'hello'
  ..favoriteCount = 0
  ..replyCount = 0
  ..favorited = favorited
  ..bookmarked = bookmarked
  ..createdAt = DateTime.utc(2026, 1, 1)
  ..user = (UserWithExtra()
    ..idStr = 'author'
    ..name = 'Author'
    ..screenName = 'author');

Widget harness(TweetWithCard tweet, LikedTweetModel model) => MaterialApp(
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
        optionUseAbsoluteTimestamp: false,
      },
    ),
    child: Provider<LikedTweetModel>.value(
      value: model,
      child: Scaffold(body: TweetTile(clickable: true, tweet: tweet)),
    ),
  ),
);

void main() {
  testWidgets('Should show independent online, local, and bookmark states', (
    tester,
  ) async {
    final model = _LikedIdsModel({'1'});
    addTearDown(model.destroy);

    await tester.pumpWidget(
      harness(post(favorited: true, bookmarked: true), model),
    );

    expect(
      find.text(L10n.current.label_liked),
      findsOneWidget,
      reason: 'A post liked by the online account needs its own badge',
    );
    expect(
      find.text(L10n.current.label_liked_here),
      findsOneWidget,
      reason: 'The local like is a separate state and can coexist with the online one',
    );
    expect(
      find.text(L10n.current.label_saved),
      findsOneWidget,
      reason: 'The X bookmark flag must identify a saved post',
    );
    expect(
      find.text('New'),
      findsNothing,
      reason: 'The freshness labels were replaced, not kept as a second tag',
    );
    expect(
      find.text('Old'),
      findsNothing,
      reason: 'The freshness labels were replaced, not kept as a second tag',
    );
  });

  testWidgets('Should hide every relationship badge when none applies', (
    tester,
  ) async {
    final model = _LikedIdsModel({});
    addTearDown(model.destroy);

    await tester.pumpWidget(harness(post(), model));

    expect(
      find.text(L10n.current.label_liked),
      findsNothing,
      reason: 'A post the online account has not liked must not claim it did',
    );
    expect(
      find.text(L10n.current.label_liked_here),
      findsNothing,
      reason: 'A post not liked locally must not show the local badge',
    );
    expect(
      find.text(L10n.current.label_saved),
      findsNothing,
      reason: 'A post not bookmarked must not show Saved',
    );
  });

  testWidgets('Should read the relationship state of a reposted original', (
    tester,
  ) async {
    final original = post(id: 'original', favorited: true, bookmarked: true);
    final wrapper = TweetWithCard()
      ..idStr = 'wrapper'
      ..fullText = 'repost'
      ..favoriteCount = 0
      ..replyCount = 0
      ..favorited = false
      ..bookmarked = false
      ..createdAt = DateTime.utc(2026, 1, 1)
      ..user = (UserWithExtra()
        ..idStr = 'reposter'
        ..name = 'Reposter'
        ..screenName = 'reposter')
      ..retweetedStatus = original
      ..retweetedStatusWithCard = original;
    final model = _LikedIdsModel({});
    addTearDown(model.destroy);

    await tester.pumpWidget(harness(wrapper, model));

    expect(
      find.text(L10n.current.label_liked),
      findsOneWidget,
      reason: 'The card shows the original post, so its online like is what the reader sees',
    );
    expect(
      find.text(L10n.current.label_saved),
      findsOneWidget,
      reason: 'A bookmark on the original must survive the repost wrapper',
    );
  });
}
