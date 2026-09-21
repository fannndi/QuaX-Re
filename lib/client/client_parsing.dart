part of 'client.dart';

/// Reads a UserByScreenName or UserByRestId body. Separate from the request so
/// a recorded response can be replayed through the very same code.
Profile parseProfile(Map<String, dynamic> content, String uri) {
  var hasErrors = content.containsKey('errors');
  if (hasErrors && content['errors'] != null) {
    var errors = List.from(content['errors']);
    if (errors.isEmpty) {
      throw TwitterError(code: 0, message: 'Unknown error', uri: uri);
    } else {
      throw TwitterError(code: errors.first['code'], message: errors.first['message'], uri: uri);
    }
  }

  var result = content['data']?['user']?['result'];
  if (result == null) {
    throw TwitterError(uri: uri, code: 50, message: L10n.current.user_not_found);
  }

  var resultType = result['__typename'];
  if (resultType != null) {
    switch (resultType) {
      case 'UserUnavailable':
        var code = result['reason'];
        if (code == 'Suspended') {
          throw TwitterError(code: 63, message: result['reason'], uri: uri);
        } else {
          throw TwitterError(code: -1, message: result['reason'], uri: uri);
        }
      case 'User':
        // This means everything's fine
        break;
      default:
        break;
    }
  }

  var user = UserWithExtra.fromNonLegacyJson(result);

  return Profile(user, UserWithExtra.pinnedTweetIdsOf(result));
}

// GraphQL "Following"


/// Reads a Following or Followers body; both share the timeline shape.
PaginatedUsers parseFollows(Map<String, dynamic> body) {
  var users = PaginatedUsers()..users = [];
  dynamic instructions =
      body["data"]?["user"]?["result"]?["timeline"]?["timeline"]?["instructions"];
  for (final instruction in instructions ?? const []) {
      if (instruction["type"] != "TimelineAddEntries" || instruction["entries"] == null) continue;
      var entries = List.from(instruction["entries"]);
      users.nextCursorStr = getCursor(entries, [], 'cursor-bottom', 'Bottom');
      users.previousCursorStr = getCursor(entries, [], 'cursor-top', 'Top');
      for (final entry in entries) {
        final userResult = entry["content"]?["itemContent"]?["user_results"]?["result"];
        if (userResult == null) continue;
        var user = UserWithExtra()
          ..screenName = userResult["core"]?["screen_name"]
          ..name = userResult["core"]?["name"]
          ..profileImageUrlHttps = userResult["avatar"]?["image_url"]
          ..verified = userResult["is_blue_verified"]
          ..createdAt = convertTwitterDateTime(userResult["core"]?["created_at"])
          ..idStr = userResult["rest_id"];
        users.users!.add(user);
    }
  }
  return users;
}


bool isNotPromoted(Map<String, dynamic> item) {
  final bool entryIdContainsPromoted = item['entryId']?.contains("promoted") ?? false;
  final bool hasPromotedMetadata = item['item']?['itemContent']?.containsKey("promotedMetadata") ?? false;
  return !(entryIdContainsPromoted || hasPromotedMetadata);
}

/// Parses one tweet result, isolating failures: a single unparseable tweet is
/// logged and skipped instead of taking the whole page down with it.
TweetWithCard? _parseTweet(dynamic result) {
  if (result is! Map<String, dynamic>) {
    return null;
  }
  try {
    return TweetWithCard.fromGraphqlJson(result);
  } catch (e) {
    _QuackerTwitterClient.log.warning('Skipping an unparseable tweet (${result['rest_id'] ?? '?'}): $e');
    return null;
  }
}

List<TweetChain> createTweetChains(List<dynamic> addEntries) {
  List<TweetChain> replies = [];

  for (var entry in addEntries) {
    final entryId = entry['entryId'];
    if (entryId is! String) continue;

    if (entryId.startsWith('tweet-')) {
      dynamic result;
      final tweetResult = entry['content']?['itemContent']?['tweet_results']?['result'];

      // This may happen for tweets that x.com cannot open neither
      if (tweetResult is! Map<String, dynamic>) continue;

      if (tweetResult['__typename'] == 'TweetWithVisibilityResults') {
        result = tweetResult['tweet'];
      } else {
        result = tweetResult;
      }

      if (result is Map<String, dynamic> && result['rest_id'] != null) {
        final tweet = _parseTweet(result);
        if (tweet == null) continue;
        replies.add(TweetChain(id: result['rest_id'], tweets: [tweet], isPinned: false));
      } else {
        replies.add(TweetChain(id: entryId.substring(6), tweets: [TweetWithCard.tombstone({})], isPinned: false));
      }
    }

    if (entryId.startsWith('cursor-bottom') || entryId.startsWith('cursor-showMore')) {
      // TODO: Use as the "next page" cursor
    }

    if (entryId.startsWith('conversationthread')) {
      List<TweetWithCard> tweets = [];

      // TODO: This is missing tombstone support
      for (var item in entry['content']?['items']?.where((e) => isNotPromoted(e)) ?? const []) {
        final itemContent = item['item']?['itemContent'];
        if (itemContent?['itemType'] != 'TimelineTweet') continue;
        final tweet = _parseTweet(itemContent?['tweet_results']?['result']);
        if (tweet != null) {
          tweets.add(tweet);
        }
      }

      // TODO: There must be a better way of getting the conversation ID
      replies.add(TweetChain(id: entryId.replaceFirst('conversationthread-', ''), tweets: tweets, isPinned: false));
    }
  }

  return replies;
}

List<TweetChain> createTweets(List<dynamic> addEntries, [bool isPinned = false]) {
  List<TweetChain> replies = [];

  for (var entry in addEntries) {
    final entryId = entry['entryId'];
    if (entryId is! String) continue;

    if (entryId.startsWith('tweet-')) {
      final result = entry['content']?['itemContent']?['tweet_results']?['result'];
      if (result is! Map<String, dynamic>) continue;

      final id = (result['rest_id'] ?? result['tweet']?['rest_id']) as String?;
      if (id == null) continue;

      final tweet = _parseTweet(result);
      if (tweet == null) continue;

      replies.add(TweetChain(id: id, tweets: [tweet], isPinned: isPinned));
    } else if (entryId.startsWith('profile-grid-')) {
      // We got a tweet queried from the media tab
      for (var mediaTweet in entry['content']?['items'] ?? const []) {
        final result = mediaTweet['item']?['itemContent']?['tweet_results']?['result'];
        if (result is! Map<String, dynamic>) continue;

        final id = (result['rest_id'] ?? result['tweet']?['rest_id']) as String?;
        if (id == null) continue;

        final tweet = _parseTweet(result);
        if (tweet == null) continue;

        replies.add(TweetChain(id: id, tweets: [tweet], isPinned: isPinned));
      }
    }

    if (entryId.startsWith('cursor-bottom') || entryId.startsWith('cursor-showMore')) {
      // TODO: Use as the "next page" cursor
    }

    if (entryId.startsWith('profile-conversation')) {
      List<TweetWithCard> tweets = [];

      // TODO: This is missing tombstone support
      for (var item in entry['content']?['items'] ?? const []) {
        final itemContent = item['item']?['itemContent'];
        if (itemContent?['itemType'] != 'TimelineTweet') continue;
        final tweet = _parseTweet(itemContent?['tweet_results']?['result']);
        if (tweet != null) {
          tweets.add(tweet);
        }
      }

      // TODO: There must be a better way of getting the conversation ID
      replies.add(TweetChain(id: entryId.replaceFirst('profile-conversation-', ''), tweets: tweets, isPinned: false));
    }
  }
  return replies;
}


/// Reads a TweetDetail body: the focal tweet and the conversation under it.
TweetStatus parseTweetDetail(Map<String, dynamic> result) {
  var instructions = List.from(result['data']?['threaded_conversation_with_injections_v2']?['instructions'] ?? []);
  if (instructions.isEmpty) {
    return TweetStatus(chains: [], cursorBottom: null, cursorTop: null);
  }

  var addEntriesInstructions = instructions.firstWhereOrNull((e) => e['type'] == 'TimelineAddEntries');
  if (addEntriesInstructions == null) {
    return TweetStatus(chains: [], cursorBottom: null, cursorTop: null);
  }

  var addEntries = List.from(addEntriesInstructions['entries']);
  var repEntries = List.from(instructions.where((e) => e['type'] == 'TimelineReplaceEntry'));

  // TODO: Could this use createUnconversationedChains at some point?
  var chains = createTweetChains(addEntries);

  String? cursorBottom = getCursor(addEntries, repEntries, 'cursor-bottom', 'Bottom');
  String? cursorTop = getCursor(addEntries, repEntries, 'cursor-top', 'Top');

  return TweetStatus(chains: chains, cursorBottom: cursorBottom, cursorTop: cursorTop);
}


/// Reads a SearchTimeline body. The Media tab answers with a grid of modules
/// rather than a list of entries, hence the branch.
TweetStatus parseSearchTimeline(
  Map<String, dynamic> result, {
  String product = "Latest",
}) {
  var timeline = result['data']?['search_by_raw_query']?['search_timeline'];
  if (timeline == null) {
    return TweetStatus(chains: [], cursorBottom: null, cursorTop: null);
  }

  if (product == "Media") {
    return _createChainsFromGridModule(timeline);
  }

  return createUnconversationedChainsGraphql(timeline, 'tweet', [], true);
}

TweetStatus _createChainsFromGridModule(Map<String, dynamic> timeline) {
  var instructions = List.from(timeline['timeline']?['instructions'] ?? []);
  var addEntries = List.from(
      instructions.firstWhereOrNull((e) => e['type'] == 'TimelineAddEntries')?['entries'] ?? []);
  var addModItems = List.from(
      instructions.firstWhereOrNull((e) => e['type'] == 'TimelineAddToModule')?['moduleItems'] ?? []);
  var repEntries = List.from(instructions.where((e) => e['type'] == 'TimelineReplaceEntry'));

  String? cursorBottom = getCursor(addEntries, repEntries, 'cursor-bottom', 'Bottom');
  String? cursorTop = getCursor(addEntries, repEntries, 'cursor-top', 'Top');

  var moduleItems = [
    ...addEntries
        .where((e) => e['content']?['entryType'] == 'TimelineTimelineModule')
        .expand((e) => List.from(e['content']?['items'] ?? [])),
    ...addModItems,
  ];

  List<TweetChain> chains = [];
  for (var item in moduleItems) {
    var result = item['item']?['itemContent']?['tweet_results']?['result'] ??
        item['item']?['content']?['tweetResult']?['result'] ??
        item['item']?['content']?['tweet_results']?['result'];
    result = result?['rest_id'] != null ? result : result?['tweet'];
    if (result?['rest_id'] == null) continue;
    final tweet = _parseTweet(result);
    if (tweet == null) continue;
    chains.add(TweetChain(id: result['rest_id'], tweets: [tweet], isPinned: false));
  }

  return TweetStatus(chains: chains, cursorBottom: cursorBottom, cursorTop: cursorTop);
}


/// Reads a NotificationsTimeline body. Notification aggregates and embedded
/// tweets share one list, ordered as X returns them.
NotificationsPage parseNotifications(Map<String, dynamic> body) {
  var instructions = List.from(
    body["data"]?["viewer_v2"]?["user_results"]?["result"]?["notification_timeline"]?["timeline"]?["instructions"] ?? const [],
  );
  var addEntries = instructions.firstWhereOrNull((e) => e['type'] == 'TimelineAddEntries');

  final entries = List.from(addEntries?['entries'] ?? const []);
  final items = <Object>[];
  String? cursorBottom;

  for (final entry in entries) {
    final entryId = entry['entryId'];
    if (entryId is! String) continue;

    if (entryId.startsWith('cursor-bottom-')) {
      cursorBottom = entry['content']?['value'] as String?;
      continue;
    }
    if (!entryId.startsWith('notification-')) continue;

    final itemContent = entry['content']?['itemContent'];
    if (itemContent is! Map<String, dynamic>) continue;

    if (itemContent['__typename'] == 'TimelineNotification') {
      final notification = _parseNotificationEntry(itemContent);
      if (notification != null) {
        items.add(notification);
      }
    } else if (itemContent['__typename'] == 'TimelineTweet') {
      final tweet = _parseTweet(itemContent['tweet_results']?['result']);
      if (tweet != null) {
        items.add(TweetChain(id: tweet.idStr ?? '', tweets: [tweet], isPinned: false));
      }
    }
  }

  return NotificationsPage(entries: items, cursorBottom: cursorBottom);
}

NotificationEntry? _parseNotificationEntry(Map<String, dynamic> item) {
  if (item['__typename'] != 'TimelineNotification') return null;

  String? senderName;
  String? senderAvatarUrl;
  final template = item['template'];
  if (template is Map<String, dynamic>) {
    for (final ref in List.from(template['from_users'] ?? const [])) {
      final result = ref?['user_results']?['result'];
      if (result is! Map<String, dynamic>) continue;
      senderName = result['core']?['name'] as String?;
      senderAvatarUrl = result['avatar']?['image_url'] as String?;
      break;
    }
  }

  final tweetText = _firstNotificationTweetText(item);

  return NotificationEntry(
    icon: item['notification_icon'] as String?,
    message: item['rich_message']?['text'] as String? ?? tweetText,
    senderName: senderName,
    senderAvatarUrl: senderAvatarUrl,
    url: item['notification_url']?['url'] as String?,
    timestampMs: int.tryParse(item['timestamp_ms']?.toString() ?? ''),
  );
}

/// The first post that the notification is about, if any (a like quotes the
/// liked post text, a mention quotes it…). Null when the entry carries none.
String? _firstNotificationTweetText(Map<String, dynamic> item) {
  final template = item['template'];
  if (template is! Map<String, dynamic>) return null;
  for (final ref in List.from(template['target_objects'] ?? const [])) {
    final tweet = ref?['tweet_results']?['result'];
    if (tweet is! Map<String, dynamic>) continue;
    final text = tweet['legacy']?['full_text'] as String?;
    if (text != null) return text;
  }
  return null;
}


String? getCursor(List<dynamic> addEntries, List<dynamic> repEntries, String legacyType, String type) {
  String? cursor;

  Map<String, dynamic>? cursorEntry;

  var isLegacyCursor = addEntries.any((element) => element['entryId'].startsWith('cursor'));
  if (isLegacyCursor) {
    cursorEntry = addEntries.firstWhere((e) => e['entryId'].contains(legacyType), orElse: () => null);
  } else {
    cursorEntry = addEntries
        .where((e) => e['entryId'].startsWith('sq-C'))
        .firstWhere((e) => e['content']['operation']['cursor']['cursorType'] == type, orElse: () => null);
  }

  if (cursorEntry != null) {
    var content = cursorEntry['content'];
    if (content.containsKey('value')) {
      cursor = content['value'];
    } else if (content.containsKey('operation')) {
      cursor = content['operation']['cursor']['value'];
    } else {
      cursor = content['itemContent']['value'];
    }
  } else {
    // Look for a "replaceEntry" with the cursor
    var cursorReplaceEntry = repEntries.firstWhere(
      (e) => e.containsKey('replaceEntry')
          ? e['replaceEntry']['entryIdToReplace'].contains(type)
          : e['entry']['content']['cursorType'].contains(type),
      orElse: () => null,
    );

    if (cursorReplaceEntry != null) {
      cursor = cursorReplaceEntry.containsKey('replaceEntry')
          ? cursorReplaceEntry['replaceEntry']['entry']['content']['operation']['cursor']['value']
          : cursorReplaceEntry['entry']['content']['value'];
    }
  }

  return cursor;
}


TweetStatus createUnconversationedChainsGraphql(
  Map<String, dynamic> result,
  String tweetIndicator,
  List<String> pinnedTweets,
  bool mapToThreads,
) {
  var instructions = List.from(result['timeline']['instructions']);
  if (instructions.isEmpty || !instructions.any((e) => e['type'] == 'TimelineAddEntries')) {
    return TweetStatus(chains: [], cursorBottom: null, cursorTop: null);
  }

  var addEntries = List.from(instructions.firstWhere((e) => e['type'] == 'TimelineAddEntries')['entries']);
  var repEntries = List.from(instructions.where((e) => e['type'] == 'TimelineReplaceEntry'));

  String? cursorBottom = getCursor(addEntries, repEntries, 'cursor-bottom', 'Bottom');
  String? cursorTop = getCursor(addEntries, repEntries, 'cursor-top', 'Top');

  var tweets = _createTweetsGraphql(tweetIndicator, addEntries);

  // First, get all the IDs of the tweets we need to display.
  String? entryRestId(dynamic e) {
    var result = e['content']?['itemContent']?['tweet_results']?['result'];
    return result?['rest_id'] ?? result?['tweet']?['rest_id'];
  }

  var tweetEntries = addEntries
      .where((e) => e['entryId'].contains(tweetIndicator) && entryRestId(e) != null)
      .sorted((a, b) => b['sortIndex'].compareTo(a['sortIndex']))
      .map(entryRestId)
      .cast<String?>()
      .toList();

  Map<String, List<TweetWithCard>> conversations = tweets.values.where((e) => tweetEntries.contains(e.idStr)).groupBy(
    (e) {
      // TODO: I don't think a flag is the right way to handle this
      if (mapToThreads) {
        // Then group the tweets-to-display by their conversation ID
        return e.conversationIdStr;
      }

      return e.idStr;
    },
  ).cast<String, List<TweetWithCard>>();

  List<TweetChain> chains = [];

  // Order all the conversations by newest first (assuming the ID is an incrementing key), and create a chain from them
  for (var conversation in conversations.entries.sorted((a, b) => b.key.compareTo(a.key))) {
    var chainTweets = conversation.value.sorted((a, b) => a.idStr!.compareTo(b.idStr!)).toList();

    chains.add(TweetChain(id: conversation.key, tweets: chainTweets, isPinned: false));
  }

  // If we want to show pinned tweets, add them before the chains that we already have
  if (pinnedTweets.isNotEmpty) {
    for (var id in pinnedTweets) {
      // It's possible for the pinned tweet to either not exist, or not be returned, so handle that
      if (tweets.containsKey(id)) {
        chains.insert(0, TweetChain(id: id, tweets: [tweets[id]!], isPinned: true));
      }
    }
  }

  return TweetStatus(chains: chains, cursorBottom: cursorBottom, cursorTop: cursorTop);
}

TweetStatus createUnconversationedChains(
  Map<String, dynamic> result,
  String tweetIndicator,
  List<String> pinnedTweets,
  bool mapToThreads,
  bool includeReplies,
  bool showPinnedTweet,
  int Function() getTweetsCounter,
  void Function() increaseTweetCounter,
) {
  final timeline = result["data"]?["user"]?["result"]?["timeline_v2"] ?? result["data"]?["user"]?["result"]?["timeline"];
  var instructions = List.from(timeline?['timeline']?['instructions'] ?? []);
  var addEntriesInstructions = instructions.firstWhereOrNull((e) => e['type'] == 'TimelineAddEntries');
  var addModEntriesInstructions = instructions.firstWhereOrNull((e) => e['type'] == 'TimelineAddToModule');
  List addModEntries = List.from(addModEntriesInstructions?['moduleItems'] ?? []);

  if (addEntriesInstructions == null && addModEntries.isEmpty) {
    return TweetStatus(chains: [], cursorBottom: null, cursorTop: null);
  }

  var addPinnedTweetsInstructions = instructions.firstWhereOrNull((e) => e['type'] == 'TimelinePinEntry');
  var addEntries = List.from(addEntriesInstructions?['entries'] ?? []);
  var repEntries = List.from(instructions.where((e) => e['type'] == 'TimelineReplaceEntry'));
  List addPinnedEntries = List<dynamic>.empty(growable: true);
  if (addPinnedTweetsInstructions != null) {
    addPinnedEntries.add(addPinnedTweetsInstructions['entry']);
  }

  String? cursorBottom = getCursor(addEntries, repEntries, 'cursor-bottom', 'Bottom');
  String? cursorTop = getCursor(addEntries, repEntries, 'cursor-top', 'Top');

  var chains = createTweets(addEntries);
  // var debugTweets = json.encode(chains);
  //var debugTweets2 = json.encode(addEntries);
  var pinnedChains = createTweets(addPinnedEntries, true);

  for (final addModEntry in addModEntries) {
    final entryId = addModEntry['entryId'] as String? ?? addModEntry['entry_id'] as String? ?? '';
    if (entryId.startsWith('profile-grid-')) {
      Map<String, dynamic>? tweetResult = addModEntry['item']?['content']?['tweetResult']?['result'];
      tweetResult ??= addModEntry['item']?['itemContent']?['tweet_results']?['result'];
      tweetResult ??= addModEntry['item']?['content']?['tweet_results']?['result'];
      // fromGraphqlJson handles the TweetWithVisibilityResults wrapper itself
      final id = tweetResult == null
          ? null
          : (tweetResult['rest_id'] ?? tweetResult['tweet']?['rest_id']) as String?;
      final tweet = _parseTweet(tweetResult);
      if (id != null && tweet != null) {
        chains.add(TweetChain(id: id, tweets: [tweet], isPinned: false));
      }
    }
  }

  //If we want to show pinned tweets, add them before the others that we already have
  if (pinnedTweets.isNotEmpty & showPinnedTweet) {
    chains.insertAll(0, pinnedChains);
  }
  //To prevent infinte loading of tweets while filtering via regex , we have to count added tweets.
  //(infinite loading originating in paged_silver_builder.dart at line 246)
  //As soon as there is no tweet left that passes regex critera and we also reached maximum attemps
  //to find them, than stop loading more.
  if (chains.length < 5) {
    increaseTweetCounter();
    if (getTweetsCounter() > 5) {
      cursorBottom = null;
    }
  }
  return TweetStatus(chains: chains, cursorBottom: cursorBottom, cursorTop: cursorTop);
}


/// Decodes and parses one timeline page on a worker isolate: the body runs to
/// hundreds of KB, and the decode plus parse takes tens of milliseconds that
/// would otherwise land as dropped frames when the page arrives mid-scroll.
///
/// The "give up after repeated near-empty pages" counters belong to the feed
/// and cannot cross an isolate boundary, so the rule they drive is applied
/// here, on the calling isolate, once the parse is back.
Future<TweetStatus> parseChainsOnIsolate(
  String body, {
  required bool conversationless,
  required String tweetIndicator,
  required List<String> pinnedTweets,
  required bool mapToThreads,
  required bool includeReplies,
  required bool showPinnedTweet,
  required int Function() getTweetsCounter,
  required void Function() incrementTweetsCounter,
}) async {
  TweetStatus parse() {
    final result = jsonDecode(body) as Map<String, dynamic>;
    return conversationless
        ? createUnconversationedChains(result, tweetIndicator, pinnedTweets, mapToThreads, includeReplies,
            showPinnedTweet, () => 0, () {})
        : createTimelineChains(result, tweetIndicator, pinnedTweets, mapToThreads, includeReplies, showPinnedTweet,
            () => 0, () {});
  }

  // A tiny page (an empty one, usually) parses faster than an isolate spawns.
  final status = body.length < 50000
      ? parse()
      : await Isolate.run(() async {
          // Tombstones carry a localized message while parsing.
          await L10n.load(Locale(Intl.getCurrentLocale()));
          return parse();
        });

  if (status.chains.length >= 5) return status;

  incrementTweetsCounter();
  if (getTweetsCounter() > 5) {
    return TweetStatus(chains: status.chains, cursorBottom: null, cursorTop: status.cursorTop);
  }
  return status;
}

TweetStatus createTimelineChains(Map<String, dynamic> result,
  String tweetIndicator,
  List<String> pinnedTweets,
  bool mapToThreads,
  bool includeReplies,
  bool showPinnedTweet,
  int Function() getTweetsCounter,
  void Function() increaseTweetCounter,
) {
  var instructions = List.from(
    result["data"]?["home"]?["home_timeline_urt"]?["instructions"] ?? const [],
  );
  var addEntriesInstructions = instructions.firstWhereOrNull((e) => e['type'] == 'TimelineAddEntries');
  if (addEntriesInstructions == null) {
    return TweetStatus(chains: [], cursorBottom: null, cursorTop: null);
  }
  var addPinnedTweetsInstructions = instructions.firstWhereOrNull((e) => e['type'] == 'TimelinePinEntry');
  var addEntries = List.from(addEntriesInstructions['entries']);
  var repEntries = List.from(instructions.where((e) => e['type'] == 'TimelineReplaceEntry'));
  List addPinnedEntries = List<dynamic>.empty(growable: true);
  if (addPinnedTweetsInstructions != null) {
    addPinnedEntries.add(addPinnedTweetsInstructions['entry']);
  }

  String? cursorBottom = getCursor(addEntries, repEntries, 'cursor-bottom', 'Bottom');
  String? cursorTop = getCursor(addEntries, repEntries, 'cursor-top', 'Top');
  var chains = createTweets(addEntries);
  // var debugTweets = json.encode(chains);
  //var debugTweets2 = json.encode(addEntries);
  var pinnedChains = createTweets(addPinnedEntries, true);

  //If we want to show pinned tweets, add them before the others that we already have
  if (pinnedTweets.isNotEmpty & showPinnedTweet) {
    chains.insertAll(0, pinnedChains);
  }
  //To prevent infinte loading of tweets while filtering via regex , we have to count added tweets.
  //(infinite loading originating in paged_silver_builder.dart at line 246)
  //As soon as there is no tweet left that passes regex critera and we also reached maximum attemps
  //to find them, than stop loading more.
  if (chains.length < 5) {
    increaseTweetCounter();
    if (getTweetsCounter() > 5) {
      cursorBottom = null;
    }
  }

  return TweetStatus(chains: chains, cursorBottom: cursorBottom, cursorTop: cursorTop);
}


Map<String, TweetWithCard> _createTweetsGraphql(
  String entryPrefix,
  List<dynamic> allTweets,
) {
  bool includeTweet(dynamic t) {
    // Exclude any items that aren't tweets
    if (!t['entryId'].startsWith(entryPrefix)) {
      return false;
    }

    if (t['content']['itemContent']['promotedMetadata'] != null) {
      return false;
    }

    if (t['content']?['itemContent']?['tweet_results']?['result'] == null) {
      return false;
    }

    return true;
  }

  var filteredTweets = allTweets.where(includeTweet);

  var globalTweets = List.from(
    filteredTweets.map((e) {
      var elm = e['content']['itemContent']['tweet_results']['result'];
      if (elm is Map<String, dynamic> && elm['rest_id'] == null && elm['tweet'] != null) {
        elm = elm['tweet'];
      }

      return elm;
    }),
  );

  final tweets = globalTweets.map(_parseTweet).whereType<TweetWithCard>().toList();

  return {for (var e in tweets) if (e.idStr != null) e.idStr!: e};
}






