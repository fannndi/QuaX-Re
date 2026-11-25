import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/tweet/tweet.dart';
import 'package:quax/utils/lru_cache.dart';

/// Parsed stored posts, keyed by id + content hash: the lists rebuild their
/// visible items on every state change, and re-decoding the JSON each time is
/// pure waste while scrolling.
///
/// Bounded at 20 rather than 80 on purpose: the value is a fully-parsed
/// `TweetWithCard` holding its `Media` objects with complete `variants` lists,
/// so an entry is a multi-hundred-KB object graph. `LruCache` bounds the entry
/// *count*, not the value size — at 80 that was tens of MB of live heap the
/// reader could not get back, to save a decode that costs microseconds.
final _decodedTweets = LruCache<String, TweetWithCard>(20);

TweetWithCard _decodeTweet(String id, String content) {
  final key = '$id#${content.hashCode}';
  final cached = _decodedTweets.get(key);
  if (cached != null) return cached;

  final tweet = TweetWithCard.fromJson(jsonDecode(content));
  _decodedTweets.set(key, tweet);
  return tweet;
}

/// Renders a post stored in the local database (a liked post) as a regular
/// tweet card.
class LikedTweetTile extends StatelessWidget {
  final String id;
  final String? content;

  const LikedTweetTile({super.key, required this.id, this.content});

  @override
  Widget build(BuildContext context) {
    var content = this.content;
    if (content == null) {
      // The tweet is probably too big to fit inside the cursor and has been removed from the result set
      return LikedTweetTooLarge(id: id);
    }

    var tweet = _decodeTweet(id, content);

    return TweetTile(
      key: ValueKey(tweet.idStr!),
      tweet: tweet,
      clickable: true,
    );
  }
}

class LikedTweetTooLarge extends StatelessWidget {
  final String id;

  const LikedTweetTooLarge({super.key, required this.id});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: ListTile(
            leading: Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(L10n.current.oops_something_went_wrong),
            subtitle: Text(L10n.current.liked_tweet_too_large),
          ),
        ),
      ),
    );
  }
}
