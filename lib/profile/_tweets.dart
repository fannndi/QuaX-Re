import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/profile/_feed.dart';
import 'package:quax/user.dart';

/// The posts / posts-and-replies tabs of a profile, backed by the user
/// timelines endpoint.
class ProfileTweets extends StatelessWidget {
  final UserWithExtra user;
  final String type;
  final bool includeReplies;
  final List<String> pinnedTweets;
  final BasePrefService pref;

  const ProfileTweets(
      {super.key,
      required this.user,
      required this.type,
      required this.includeReplies,
      required this.pinnedTweets,
      required this.pref});

  @override
  Widget build(BuildContext context) {
    return ProfileTweetFeed(
      user: user,
      emptyMessage: L10n.of(context).could_not_find_any_tweets_by_this_user,
      loadPage: (cursor, getTweetsCounter, incrementTweetsCounter) => Twitter.getTweets(
        user.idStr!,
        type,
        pinnedTweets,
        cursor: cursor,
        count: 20,
        includeReplies: includeReplies,
        getTweetsCounter: getTweetsCounter,
        incrementTweetsCounter: incrementTweetsCounter,
      ),
    );
  }
}
