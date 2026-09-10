part of 'client.dart';

class TweetWithCard extends Tweet {
  String? noteText;
  Entities? noteEntities;
  Map<String, dynamic>? card;
  String? conversationIdStr;
  TweetWithCard? quotedStatusWithCard;
  TweetWithCard? retweetedStatusWithCard;
  bool? isTombstone;
  TweetWithCard? birdwatchQuotedStatus; // Community notes
  Article? article;
  int? viewCount;

  TweetWithCard();

  @override
  Map<String, dynamic> toJson() {
    var json = super.toJson();
    json['card'] = card;
    json['conversationIdStr'] = conversationIdStr;
    json['quotedStatusWithCard'] = quotedStatusWithCard?.toJson();
    json['retweetedStatusWithCard'] = retweetedStatusWithCard?.toJson();
    json['isTombstone'] = isTombstone;
    json['article'] = article?.toJson();
    json['viewCount'] = viewCount;
    json['noteText'] = noteText;
    json['noteEntities'] = noteEntities?.toJson();

    return json;
  }

  factory TweetWithCard.tombstone(dynamic e) {
    var tweetWithCard = TweetWithCard();
    tweetWithCard.idStr = '';
    tweetWithCard.isTombstone = true;
    tweetWithCard.text =
        ((e['richText']?['text'] ?? e['text']?['text'] ?? L10n.current.this_tweet_is_unavailable) as String)
            .replaceFirst(' Learn more', '');

    return tweetWithCard;
  }

  factory TweetWithCard.fromJson(Map<String, dynamic> e) {
    var tweet = Tweet.fromJson(e);

    var tweetWithCard = TweetWithCard();
    tweetWithCard.card = e['card'];
    tweetWithCard.conversationIdStr = e['conversationIdStr'];
    tweetWithCard.createdAt = tweet.createdAt;
    tweetWithCard.entities = tweet.entities;
    tweetWithCard.displayTextRange = tweet.displayTextRange;
    tweetWithCard.extendedEntities = tweet.extendedEntities;
    tweetWithCard.favorited = tweet.favorited;
    tweetWithCard.favoriteCount = tweet.favoriteCount;
    tweetWithCard.fullText = tweet.fullText;
    tweetWithCard.idStr = tweet.idStr;
    tweetWithCard.inReplyToScreenName = tweet.inReplyToScreenName;
    tweetWithCard.inReplyToStatusIdStr = tweet.inReplyToStatusIdStr;
    tweetWithCard.inReplyToUserIdStr = tweet.inReplyToUserIdStr;
    tweetWithCard.isQuoteStatus = tweet.isQuoteStatus;
    tweetWithCard.isTombstone = e['isTombstone'];
    tweetWithCard.lang = tweet.lang;
    tweetWithCard.quoteCount = tweet.quoteCount;
    tweetWithCard.quotedStatusIdStr = tweet.quotedStatusIdStr;
    tweetWithCard.quotedStatusPermalink = tweet.quotedStatusPermalink;
    tweetWithCard.quotedStatusWithCard = e['quotedStatusWithCard'] == null
        ? null
        : TweetWithCard.fromJson(e['quotedStatusWithCard']);
    tweetWithCard.replyCount = tweet.replyCount;
    tweetWithCard.retweetCount = tweet.retweetCount;
    tweetWithCard.retweeted = tweet.retweeted;
    tweetWithCard.retweetedStatus = tweet.retweetedStatus;
    tweetWithCard.retweetedStatusWithCard = e['retweetedStatusWithCard'] == null
        ? null
        : TweetWithCard.fromJson(e['retweetedStatusWithCard']);
    tweetWithCard.viewCount = e['viewCount'];
    tweetWithCard.source = tweet.source;
    tweetWithCard.text = tweet.text;
    tweetWithCard.user = tweet.user;
    tweetWithCard.coordinates = tweet.coordinates;
    tweetWithCard.truncated = tweet.truncated;
    tweetWithCard.place = tweet.place;
    tweetWithCard.possiblySensitive = tweet.possiblySensitive;
    tweetWithCard.possiblySensitiveAppealable = tweet.possiblySensitiveAppealable;
    tweetWithCard.article = e['article'] == null ? null : Article.fromJson(e['article']);
    tweetWithCard.noteText = e['noteText'];
    tweetWithCard.noteEntities = e['noteEntities'] == null ? null : Entities.fromJson(e['noteEntities']);

    return tweetWithCard;
  }

  factory TweetWithCard.fromGraphqlJson(Map<String, dynamic> result) {
    dynamic retweetedStatus;
    dynamic quotedStatus;
    dynamic user;

    if (result['tweet'] != null) {
      result = result['tweet']!;
    } else if (result['legacy']?['retweeted_status_result']?['result'] != null) {
      retweetedStatus = _parseTweet(result['legacy']['retweeted_status_result']['result']);
    }

    if (result['quoted_status_result'] != null && result['quoted_status_result']['result'] != null) {
      // tweets that limit who can reply (TweetWithVisibilityResults) are wrapped in another layer
      var quotedTweetResult = result['quoted_status_result']['result']?['__typename'] == 'TweetWithVisibilityResults'
          ? result['quoted_status_result']['result']['tweet']
          : result['quoted_status_result']['result'];
      if (quotedTweetResult is Map<String, dynamic>) {
        quotedStatus = _parseTweet(quotedTweetResult);
      }
    }

    var resCore = result['core']?['user_results']?['result'];
    if (resCore is Map<String, dynamic> && resCore['rest_id'] != null) {
      user = UserWithExtra.fromNonLegacyJson(resCore);
    }

    String? noteText;
    Entities? noteEntities;

    var noteResult = result['note_tweet']?['note_tweet_results']?['result'];
    if (noteResult is Map<String, dynamic>) {
      noteText = noteResult['text'];
      noteEntities = Entities.fromJson(noteResult['entity_set']);
    }

    if (result['tombstone'] != null) {
      return TweetWithCard.tombstone(result['tombstone']!);
    }

    // Some results (suspended/unavailable/visibility-restricted tweets) carry no
    // `legacy` payload and no `tombstone`, so there is nothing to build from.
    if (result['legacy'] == null) {
      return TweetWithCard.tombstone(result);
    }

    var tweet = TweetWithCard.fromData(
        result['legacy'],
        noteText,
        noteEntities,
        user,
        retweetedStatus,
        quotedStatus,
        int.tryParse(result['views']?['count'] ?? ''));

    if (tweet.card == null && result['card']?['legacy'] != null) {
      tweet.card = result['card']['legacy'];
      var bindingValuesList = tweet.card!['binding_values'] as List?;
      if (bindingValuesList != null) {
        var bindingValues = <String, dynamic>{};
        for (var elm in bindingValuesList) {
          bindingValues[elm['key'] as String] = elm['value'];
        }
        tweet.card!['binding_values'] = bindingValues;
      }
    }
    if (result['birdwatch_pivot']?['subtitle'] != null) {
      var birdwatchSubtitle = TweetWithCard.rearrangeBirdwatch(result['birdwatch_pivot']['subtitle']);
      tweet.birdwatchQuotedStatus = TweetWithCard.fromJson(birdwatchSubtitle);
    }

    final article = result['article']?["article_results"]?["result"] ?? result['article']?['article'];

    if (article != null) {
      tweet.article = Article.fromGraphqlJson(
        article,
        tweet.idStr ?? "",
        tweet.user?.screenName ?? "",
      );
    }

    return tweet;
  }

  static Map<String, dynamic> rearrangeBirdwatch(Map<String, dynamic> birdwatch) {
    Map<String, dynamic> newBirdwatch = {};
    String text = birdwatch['text'];
    newBirdwatch['text'] = text;
    newBirdwatch['display_text_range'] = [0, text.length - 1];
    var entities = birdwatch['entities'];
    newBirdwatch['entities'] = {"urls": []};
    for (final entity in entities) {
      int fromIndex = entity['fromIndex'];
      int toIndex = entity['toIndex'];
      String displayedUrl = text.substring(fromIndex, toIndex);
      String url = entity['ref']['url'];
      newBirdwatch['entities']["urls"].add({
        'display_url': displayedUrl,
        'expanded_url': url,
        'url': url,
        'indices': [fromIndex, toIndex],
      });
    }
    return newBirdwatch;
  }

  factory TweetWithCard.fromCardJson(Map<String, dynamic> tweets, Map<String, dynamic> users, Map<String, dynamic> e) {
    var user = e['user_id_str'] == null ? null : UserWithExtra.fromJson(users[e['user_id_str']]);

    var retweetedStatus = e['retweeted_status_id_str'] == null
        ? null
        : TweetWithCard.fromCardJson(tweets, users, tweets[e['retweeted_status_id_str']]);

    // Some quotes aren't returned, even though we're given their ID, so double check and don't fail with a null value
    TweetWithCard? quotedStatus;
    var quoteId = e['quoted_status_id_str'];
    if (quoteId != null && tweets[quoteId] != null) {
      quotedStatus = TweetWithCard.fromCardJson(tweets, users, tweets[quoteId]);
    }

    return TweetWithCard.fromData(e, null, null, user, retweetedStatus, quotedStatus, null);
  }

  factory TweetWithCard.fromData(
    Map<String, dynamic> e,
    String? noteText,
    Entities? noteEntities,
    UserWithExtra? user,
    TweetWithCard? retweetedStatus,
    TweetWithCard? quotedStatus,
    int? tweetViewCount,
  ) {
    TweetWithCard tweet = TweetWithCard();
    tweet.card = e['card'];
    tweet.conversationIdStr = e['conversation_id_str'];
    tweet.createdAt = convertTwitterDateTime(e['created_at']);
    tweet.entities = e['entities'] == null ? null : Entities.fromJson(e['entities']);
    tweet.extendedEntities = e['extended_entities'] == null ? null : Entities.fromJson(e['extended_entities']);
    tweet.favorited = e['favorited'] as bool?;
    tweet.favoriteCount = e['favorite_count'] as int?;
    tweet.viewCount = tweetViewCount;
    tweet.fullText = e['full_text'] as String?;
    tweet.idStr = e['id_str'] as String?;
    tweet.inReplyToScreenName = e['in_reply_to_screen_name'] as String?;
    tweet.inReplyToStatusIdStr = e['in_reply_to_status_id_str'] as String?;
    tweet.inReplyToUserIdStr = e['in_reply_to_user_id_str'] as String?;
    tweet.isQuoteStatus = e['is_quote_status'] as bool?;
    tweet.isTombstone = e['is_tombstone'] as bool?;
    tweet.lang = e['lang'] as String?;
    tweet.possiblySensitive = e['possibly_sensitive'] as bool?;
    tweet.quoteCount = e['quote_count'] as int?;
    tweet.quotedStatusIdStr = e['quoted_status_id_str'] as String?;
    tweet.quotedStatusPermalink = e['quoted_status_permalink'] == null
        ? null
        : QuotedStatusPermalink.fromJson(e['quoted_status_permalink']);
    tweet.replyCount = e['reply_count'] as int?;
    tweet.retweetCount = e['retweet_count'] as int?;
    tweet.retweeted = e['retweeted'] as bool?;
    tweet.source = e['source'] as String?;
    tweet.text = e['text'] ?? e['full_text'] as String?;
    tweet.user = user;

    if (tweet.user != null) {
      tweet.user!.idStr = e['user_id_str'];
    }

    tweet.retweetedStatus = retweetedStatus;
    tweet.retweetedStatusWithCard = retweetedStatus;
    tweet.quotedStatus = quotedStatus;
    tweet.quotedStatusWithCard = quotedStatus;

    tweet.displayTextRange = (e['display_text_range'] as List<dynamic>?)?.map((e) => e as int).toList();

    // TODO
    tweet.coordinates = null;
    tweet.truncated = null;
    tweet.place = null;
    tweet.possiblySensitiveAppealable = null;

    // notes are a new kind of tweets that can be longer, compared to old ones now marked as "legacy" but still used
    tweet.noteText = noteText;
    tweet.noteEntities = noteEntities;

    return tweet;
  }

  static Entities copyEntities(Entities src, Entities trg) {
    if (src.media != null) {
      trg.media = src.media;
    }
    if (src.urls != null) {
      trg.urls = src.urls;
    }
    if (src.userMentions != null) {
      trg.userMentions = src.userMentions;
    }
    if (src.hashtags != null) {
      trg.hashtags = src.hashtags;
    }
    if (src.symbols != null) {
      trg.symbols = src.symbols;
    }
    if (src.polls != null) {
      trg.polls = src.polls;
    }
    return trg;
  }
}

class TweetChain {
  final String id;
  final List<TweetWithCard> tweets;
  final bool isPinned;

  TweetChain({required this.id, required this.tweets, required this.isPinned});

  factory TweetChain.fromJson(Map<String, dynamic> e) {
    var tweets = List.from(e['tweets']).map((e) => TweetWithCard.fromJson(e)).toList();

    return TweetChain(id: e['id'], tweets: tweets, isPinned: e['isPinned']);
  }

  Map<String, dynamic> toJson() {
    return {'id': id, 'tweets': tweets.map((e) => e.toJson()).toList(), 'isPinned': isPinned};
  }
}

class Follows {
  final String? cursorBottom;
  final String? cursorTop;
  final List<UserWithExtra> users;

  Follows({required this.cursorBottom, required this.cursorTop, required this.users});
}

/// One aggregated notification (likes, replies, bell-subscribed posts…). Its
/// parts are optional: X fills what the notification supports.
class NotificationEntry {
  final String? icon;
  final String? message;
  final String? senderName;
  final String? senderAvatarUrl;
  final String? url;
  final int? timestampMs;

  NotificationEntry({this.icon, this.message, this.senderName, this.senderAvatarUrl, this.url, this.timestampMs});
}

/// One page of the notifications timeline: notification aggregates and embedded
/// tweets (TweetChain) interleaved, plus the bottom cursor for pagination.
class NotificationsPage {
  final List<Object> entries;
  final String? cursorBottom;

  NotificationsPage({required this.entries, required this.cursorBottom});
}

class TweetStatus {
  // final TweetChain after;
  // final TweetChain before;
  final String? cursorBottom;
  final String? cursorTop;
  final List<TweetChain> chains;

  TweetStatus({required this.chains, required this.cursorBottom, required this.cursorTop});
}

class TwitterError {
  final String uri;
  final int code;
  final String message;

  TwitterError({required this.uri, required this.code, required this.message});

  @override
  String toString() {
    return 'TwitterError{code: $code, message: $message, url: $uri}';
  }
}

class SearchHasNoTimelineException {
  final String? query;

  SearchHasNoTimelineException(this.query);

  @override
  String toString() {
    return 'The search has no timeline {query: $query}';
  }
}

class UnknownTimelineItemType with SyntheticException implements Exception {
  final String type;
  final String entryId;

  UnknownTimelineItemType(this.type, this.entryId);

  @override
  String toString() {
    return 'Unknown timeline item type: {type: $type, entryId: $entryId}';
  }
}

