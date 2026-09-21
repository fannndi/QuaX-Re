import 'dart:convert';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/tweet/tweet.dart';

/// Renders a post stored in the local database (saved or liked) as a regular
/// tweet card.
class SavedTweetTile extends StatelessWidget {
  final String id;
  final String? content;

  const SavedTweetTile({super.key, required this.id, this.content});

  @override
  Widget build(BuildContext context) {
    var content = this.content;
    if (content == null) {
      // The tweet is probably too big to fit inside the cursor and has been removed from the result set
      return SavedTweetTooLarge(id: id);
    }

    var tweet = TweetWithCard.fromJson(jsonDecode(content));

    return TweetTile(key: Key(tweet.idStr!), tweet: tweet, clickable: true);
  }
}

class SavedTweetTooLarge extends StatelessWidget {
  final String id;

  const SavedTweetTooLarge({super.key, required this.id});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading:
                  Icon(Icons.error_outline, color: Colors.red.harmonizeWith(Theme.of(context).colorScheme.primary)),
              title: Text(L10n.current.oops_something_went_wrong),
              subtitle: Text(L10n.current.saved_tweet_too_large),
            ),
          ],
        ),
      ),
    );
  }
}
