import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:quax/client/client.dart';
import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/profile/_feed.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/user.dart';

/// The "Likes" timeline of an account, backed by X's Likes endpoint. X only
/// answers this for the account the request runs as, so it is reachable from
/// the Account settings for the active account.
class ProfileLikes extends StatelessWidget {
  final UserWithExtra user;

  const ProfileLikes({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    return ProfileTweetFeed(
      user: user,
      emptyMessage: L10n.of(context).no_liked_posts_yet,
      loadPage: (cursor, getTweetsCounter, incrementTweetsCounter) => Twitter.getLikes(
        user.idStr!,
        cursor: cursor,
        count: 20,
        getTweetsCounter: getTweetsCounter,
        incrementTweetsCounter: incrementTweetsCounter,
      ),
    );
  }
}

/// Standalone screen for the account settings' "My likes" entry.
class ProfileLikesScreen extends StatelessWidget {
  final UserWithExtra user;

  const ProfileLikesScreen({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    final prefs = PrefService.of(context);
    return ChangeNotifierProvider<TweetContextState>(
      create: (_) => TweetContextState(prefs.get(optionTweetsHideSensitive)),
      child: Scaffold(
        appBar: AppBar(title: Text(L10n.of(context).favorites)),
        body: ProfileLikes(user: user),
      ),
    );
  }
}
