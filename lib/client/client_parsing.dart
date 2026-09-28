part of 'client.dart';

/// Reads a UserByScreenName or UserByRestId body. Separate from the request so
/// a recorded response can be replayed through the very same code.
Profile parseProfile(Map<String, dynamic> content, String uri) {
  // An error body can carry anything; never trust its shape.
  final errors = content['errors'];
  if (errors is List && errors.isNotEmpty) {
    final first = errors.first;
    if (first is Map<String, dynamic>) {
      throw TwitterError(
        code: (first['code'] as num?)?.toInt() ?? 0,
        message: first['message']?.toString() ?? 'Unknown error',
        uri: uri,
      );
    }
    throw TwitterError(code: 0, message: 'Unknown error', uri: uri);
  }

  var result = content['data']?['user']?['result'];
  if (result == null) {
    throw TwitterError(
      uri: uri,
      code: 50,
      message: L10n.current.user_not_found,
    );
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
    if (instruction["type"] != "TimelineAddEntries" ||
        instruction["entries"] == null) {
      continue;
    }
    var entries = List.from(instruction["entries"]);
    users.nextCursorStr = getCursor(entries, [], 'cursor-bottom', 'Bottom');
    users.previousCursorStr = getCursor(entries, [], 'cursor-top', 'Top');
    for (final entry in entries) {
      final userResult =
          entry["content"]?["itemContent"]?["user_results"]?["result"];
      if (userResult is! Map<String, dynamic>) continue;
      try {
        // Modern users share the mapping with profiles (bio, counts…);
        // a malformed entry is skipped instead of emptying the page.
        users.users!.add(UserWithExtra.fromNonLegacyJson(userResult));
      } catch (e) {
        _QuackerTwitterClient.log.warning('Skipping an unparseable user: $e');
      }
    }
  }
  return users;
}

bool isNotPromoted(Map<String, dynamic> item) {
  final bool entryIdContainsPromoted =
      item['entryId']?.contains("promoted") ?? false;
  final bool hasPromotedMetadata =
      item['item']?['itemContent']?.containsKey("promotedMetadata") ?? false;
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
    _QuackerTwitterClient.log.warning(
      'Skipping an unparseable tweet (${result['rest_id'] ?? '?'}): $e',
    );
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
      final tweetResult =
          entry['content']?['itemContent']?['tweet_results']?['result'];

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
        replies.add(
          TweetChain(
            id: result['rest_id'].toString(),
            tweets: [tweet],
            isPinned: false,
          ),
        );
      } else {
        replies.add(
          TweetChain(
            id: entryId.substring(6),
            tweets: [TweetWithCard.tombstone({})],
            isPinned: false,
          ),
        );
      }
    }

    if (entryId.startsWith('cursor-bottom') ||
        entryId.startsWith('cursor-showMore')) {
      // TODO: Use as the "next page" cursor
    }

    if (entryId.startsWith('conversationthread')) {
      List<TweetWithCard> tweets = [];

      for (var item
          in entry['content']?['items']?.where((e) => isNotPromoted(e)) ??
              const []) {
        final itemContent = item['item']?['itemContent'];
        if (itemContent?['itemType'] != 'TimelineTweet') continue;
        final tweetResult = itemContent?['tweet_results']?['result'];
        final tweet = _parseTweet(tweetResult);
        if (tweet != null) {
          tweets.add(tweet);
        } else if (tweetResult is! Map<String, dynamic>) {
          // A deleted or unavailable reply shows its tombstone, like the
          // top-level tweet- entries do, instead of vanishing from the thread.
          tweets.add(TweetWithCard.tombstone({}));
        }
      }

      // TODO: There must be a better way of getting the conversation ID
      replies.add(
        TweetChain(
          id: entryId.replaceFirst('conversationthread-', ''),
          tweets: tweets,
          isPinned: false,
        ),
      );
    }
  }

  return replies;
}

List<TweetChain> createTweets(
  List<dynamic> addEntries, [
  bool isPinned = false,
]) {
  List<TweetChain> replies = [];

  for (var entry in addEntries) {
    final entryId = entry['entryId'];
    if (entryId is! String) continue;

    if (entryId.startsWith('tweet-')) {
      final result =
          entry['content']?['itemContent']?['tweet_results']?['result'];
      if (result is! Map<String, dynamic>) continue;

      final id = (result['rest_id'] ?? result['tweet']?['rest_id'])?.toString();
      if (id == null || id.isEmpty) continue;

      final tweet = _parseTweet(result);
      if (tweet == null) continue;

      replies.add(TweetChain(id: id, tweets: [tweet], isPinned: isPinned));
    } else if (entryId.startsWith('profile-grid-')) {
      // We got a tweet queried from the media tab
      for (var mediaTweet in entry['content']?['items'] ?? const []) {
        final result =
            mediaTweet['item']?['itemContent']?['tweet_results']?['result'];
        if (result is! Map<String, dynamic>) continue;

        final id = (result['rest_id'] ?? result['tweet']?['rest_id'])
            ?.toString();
        if (id == null || id.isEmpty) continue;

        final tweet = _parseTweet(result);
        if (tweet == null) continue;

        replies.add(TweetChain(id: id, tweets: [tweet], isPinned: isPinned));
      }
    }

    if (entryId.startsWith('cursor-bottom') ||
        entryId.startsWith('cursor-showMore')) {
      // TODO: Use as the "next page" cursor
    }

    if (entryId.startsWith('profile-conversation')) {
      List<TweetWithCard> tweets = [];

      for (var item in entry['content']?['items'] ?? const []) {
        final itemContent = item['item']?['itemContent'];
        if (itemContent?['itemType'] != 'TimelineTweet') continue;
        final tweetResult = itemContent?['tweet_results']?['result'];
        final tweet = _parseTweet(tweetResult);
        if (tweet != null) {
          tweets.add(tweet);
        } else if (tweetResult is! Map<String, dynamic>) {
          // See conversationthread: keep unavailable replies visible.
          tweets.add(TweetWithCard.tombstone({}));
        }
      }

      // TODO: There must be a better way of getting the conversation ID
      replies.add(
        TweetChain(
          id: entryId.replaceFirst('profile-conversation-', ''),
          tweets: tweets,
          isPinned: false,
        ),
      );
    }
  }
  return replies;
}

/// Reads a TweetDetail body: the focal tweet and the conversation under it.
TweetStatus parseTweetDetail(Map<String, dynamic> result) {
  var instructions = List.from(
    result['data']?['threaded_conversation_with_injections_v2']?['instructions'] ??
        [],
  );
  if (instructions.isEmpty) {
    return TweetStatus(chains: [], cursorBottom: null, cursorTop: null);
  }

  var addEntriesInstructions = instructions.firstWhereOrNull(
    (e) => e['type'] == 'TimelineAddEntries',
  );
  if (addEntriesInstructions == null) {
    return TweetStatus(chains: [], cursorBottom: null, cursorTop: null);
  }

  var addEntries = List.from(addEntriesInstructions['entries'] ?? const []);
  var repEntries = List.from(
    instructions.where((e) => e['type'] == 'TimelineReplaceEntry'),
  );

  // TODO: Could this use createUnconversationedChains at some point?
  var chains = createTweetChains(addEntries);

  String? cursorBottom = getCursor(
    addEntries,
    repEntries,
    'cursor-bottom',
    'Bottom',
  );
  String? cursorTop = getCursor(addEntries, repEntries, 'cursor-top', 'Top');

  return TweetStatus(
    chains: chains,
    cursorBottom: cursorBottom,
    cursorTop: cursorTop,
  );
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
    instructions.firstWhereOrNull(
          (e) => e['type'] == 'TimelineAddEntries',
        )?['entries'] ??
        [],
  );
  var addModItems = List.from(
    instructions.firstWhereOrNull(
          (e) => e['type'] == 'TimelineAddToModule',
        )?['moduleItems'] ??
        [],
  );
  var repEntries = List.from(
    instructions.where((e) => e['type'] == 'TimelineReplaceEntry'),
  );

  String? cursorBottom = getCursor(
    addEntries,
    repEntries,
    'cursor-bottom',
    'Bottom',
  );
  String? cursorTop = getCursor(addEntries, repEntries, 'cursor-top', 'Top');

  var moduleItems = [
    ...addEntries
        .where((e) => e['content']?['entryType'] == 'TimelineTimelineModule')
        .expand((e) => List.from(e['content']?['items'] ?? [])),
    ...addModItems,
  ];

  List<TweetChain> chains = [];
  for (var item in moduleItems) {
    var result =
        item['item']?['itemContent']?['tweet_results']?['result'] ??
        item['item']?['content']?['tweetResult']?['result'] ??
        item['item']?['content']?['tweet_results']?['result'];
    result = result?['rest_id'] != null ? result : result?['tweet'];
    if (result?['rest_id'] == null) continue;
    final tweet = _parseTweet(result);
    if (tweet == null) continue;
    chains.add(
      TweetChain(id: result['rest_id'], tweets: [tweet], isPinned: false),
    );
  }

  return TweetStatus(
    chains: chains,
    cursorBottom: cursorBottom,
    cursorTop: cursorTop,
  );
}

/// Reads a NotificationsTimeline body. Notification aggregates and embedded
/// tweets share one list, ordered as X returns them.
NotificationsPage parseNotifications(Map<String, dynamic> body) {
  var instructions = List.from(
    body["data"]?["viewer_v2"]?["user_results"]?["result"]?["notification_timeline"]?["timeline"]?["instructions"] ??
        const [],
  );
  var addEntries = instructions.firstWhereOrNull(
    (e) => e['type'] == 'TimelineAddEntries',
  );

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
        items.add(
          TweetChain(id: tweet.idStr ?? '', tweets: [tweet], isPinned: false),
        );
      }
    }
  }

  return NotificationsPage(entries: items, cursorBottom: cursorBottom);
}

NotificationEntry? _parseNotificationEntry(Map<String, dynamic> item) {
  if (item['__typename'] != 'TimelineNotification') return null;

  try {
    return _buildNotificationEntry(item);
  } catch (e) {
    // Notifications have no per-item isolation at their call site, so one
    // malformed aggregate must be dropped instead of emptying the bell page.
    _QuackerTwitterClient.log.warning(
      'Skipping an unparseable notification: $e',
    );
    return null;
  }
}

NotificationEntry _buildNotificationEntry(Map<String, dynamic> item) {
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

String? getCursor(
  List<dynamic> addEntries,
  List<dynamic> repEntries,
  String legacyType,
  String type,
) {
  String? cursor;

  Map<String, dynamic>? cursorEntry;

  var isLegacyCursor = addEntries.any(
    (element) =>
        element is Map &&
        element['entryId'] is String &&
        (element['entryId'] as String).startsWith('cursor'),
  );
  if (isLegacyCursor) {
    cursorEntry = addEntries
        .where(
          (e) =>
              e is Map &&
              e['entryId'] is String &&
              (e['entryId'] as String).contains(legacyType),
        )
        .whereType<Map<String, dynamic>>()
        .firstOrNull;
  } else {
    cursorEntry = addEntries
        .where(
          (e) =>
              e is Map &&
              e['entryId'] is String &&
              (e['entryId'] as String).startsWith('sq-C'),
        )
        .where(
          (e) => _cursorTypeOf(e['content']?['operation']?['cursor']) == type,
        )
        .whereType<Map<String, dynamic>>()
        .firstOrNull;
  }

  if (cursorEntry != null) {
    final content = cursorEntry['content'];
    if (content is Map<String, dynamic>) {
      cursor =
          (content['value'] ??
                  content['operation']?['cursor']?['value'] ??
                  content['itemContent']?['value'])
              ?.toString();
    }
  } else {
    // Look for a "replaceEntry" with the cursor
    for (final e in repEntries) {
      if (e is! Map<String, dynamic>) continue;

      if (e.containsKey('replaceEntry')) {
        final replaceEntry = e['replaceEntry'];
        if (replaceEntry is Map<String, dynamic> &&
            replaceEntry['entryIdToReplace']?.toString().contains(type) ==
                true) {
          cursor =
              (replaceEntry['entry']?['content']?['operation']?['cursor']?['value'])
                  ?.toString();
          break;
        }
      } else if (_cursorTypeOf(e['entry']?['content']) == type) {
        cursor = (e['entry']?['content']?['value'])?.toString();
        break;
      }
    }
  }

  return cursor;
}

/// The cursor type of a cursor object, whatever shape X sends: a plain string
/// or, on older bodies, a list of tags.
String? _cursorTypeOf(dynamic cursor) {
  final cursorType = cursor?['cursorType'];
  if (cursorType is String) return cursorType;
  if (cursorType is List) return cursorType.whereType<String>().firstOrNull;
  return null;
}

TweetStatus createUnconversationedChainsGraphql(
  Map<String, dynamic> result,
  String tweetIndicator,
  List<String> pinnedTweets,
  bool mapToThreads,
) {
  var instructions = List.from(result['timeline']?['instructions'] ?? const []);
  if (instructions.isEmpty ||
      !instructions.any((e) => e is Map && e['type'] == 'TimelineAddEntries')) {
    return TweetStatus(chains: [], cursorBottom: null, cursorTop: null);
  }

  var addEntries = List.from(
    instructions.firstWhere(
          (e) => e is Map && e['type'] == 'TimelineAddEntries',
        )?['entries'] ??
        const [],
  );
  var repEntries = List.from(
    instructions.where((e) => e is Map && e['type'] == 'TimelineReplaceEntry'),
  );

  String? cursorBottom = getCursor(
    addEntries,
    repEntries,
    'cursor-bottom',
    'Bottom',
  );
  String? cursorTop = getCursor(addEntries, repEntries, 'cursor-top', 'Top');

  var tweets = _createTweetsGraphql(tweetIndicator, addEntries);

  // First, get all the IDs of the tweets we need to display.
  String? entryRestId(dynamic e) {
    var result = e['content']?['itemContent']?['tweet_results']?['result'];
    return result?['rest_id'] ?? result?['tweet']?['rest_id'];
  }

  var tweetEntries = addEntries
      .where(
        (e) =>
            e['entryId'] is String &&
            (e['entryId'] as String).contains(tweetIndicator),
      )
      .where((e) => entryRestId(e) != null)
      .sorted(
        (a, b) => (b['sortIndex']?.toString() ?? '').compareTo(
          a['sortIndex']?.toString() ?? '',
        ),
      )
      .map(entryRestId)
      .cast<String?>()
      .toList();

  Map<String, List<TweetWithCard>> conversations = tweets.values
      .where((e) => tweetEntries.contains(e.idStr))
      .groupBy((e) {
        // TODO: I don't think a flag is the right way to handle this
        if (mapToThreads) {
          // Then group the tweets-to-display by their conversation ID. A tweet
          // without one still has to land in a group of its own.
          return e.conversationIdStr ?? e.idStr ?? '';
        }

        return e.idStr ?? '';
      });

  List<TweetChain> chains = [];

  // Order all the conversations by newest first (assuming the ID is an incrementing key), and create a chain from them
  for (var conversation in conversations.entries.sorted(
    (a, b) => b.key.compareTo(a.key),
  )) {
    var chainTweets = conversation.value
        .sorted((a, b) => (a.idStr ?? '').compareTo(b.idStr ?? ''))
        .toList();

    chains.add(
      TweetChain(id: conversation.key, tweets: chainTweets, isPinned: false),
    );
  }

  // If we want to show pinned tweets, add them before the chains that we already have
  if (pinnedTweets.isNotEmpty) {
    for (var id in pinnedTweets) {
      // It's possible for the pinned tweet to either not exist, or not be returned, so handle that
      if (tweets.containsKey(id)) {
        chains.insert(
          0,
          TweetChain(id: id, tweets: [tweets[id]!], isPinned: true),
        );
      }
    }
  }

  return TweetStatus(
    chains: chains,
    cursorBottom: cursorBottom,
    cursorTop: cursorTop,
  );
}

TweetStatus createUnconversationedChains(
  Map<String, dynamic> result,
  String tweetIndicator,
  List<String> pinnedTweets,
  bool mapToThreads,
  bool showPinnedTweet,
) {
  final timeline =
      result["data"]?["user"]?["result"]?["timeline_v2"] ??
      result["data"]?["user"]?["result"]?["timeline"];
  var instructions = List.from(timeline?['timeline']?['instructions'] ?? []);
  var addEntriesInstructions = instructions.firstWhereOrNull(
    (e) => e['type'] == 'TimelineAddEntries',
  );
  var addModEntriesInstructions = instructions.firstWhereOrNull(
    (e) => e['type'] == 'TimelineAddToModule',
  );
  List addModEntries = List.from(
    addModEntriesInstructions?['moduleItems'] ?? [],
  );

  if (addEntriesInstructions == null && addModEntries.isEmpty) {
    return TweetStatus(chains: [], cursorBottom: null, cursorTop: null);
  }

  var addPinnedTweetsInstructions = instructions.firstWhereOrNull(
    (e) => e['type'] == 'TimelinePinEntry',
  );
  var addEntries = List.from(addEntriesInstructions?['entries'] ?? []);
  var repEntries = List.from(
    instructions.where((e) => e['type'] == 'TimelineReplaceEntry'),
  );
  List addPinnedEntries = List<dynamic>.empty(growable: true);
  if (addPinnedTweetsInstructions != null) {
    addPinnedEntries.add(addPinnedTweetsInstructions['entry']);
  }

  String? cursorBottom = getCursor(
    addEntries,
    repEntries,
    'cursor-bottom',
    'Bottom',
  );
  String? cursorTop = getCursor(addEntries, repEntries, 'cursor-top', 'Top');

  var chains = createTweets(addEntries);
  // var debugTweets = json.encode(chains);
  //var debugTweets2 = json.encode(addEntries);
  var pinnedChains = createTweets(addPinnedEntries, true);

  for (final addModEntry in addModEntries) {
    final entryId =
        addModEntry['entryId'] as String? ??
        addModEntry['entry_id'] as String? ??
        '';
    if (entryId.startsWith('profile-grid-')) {
      Map<String, dynamic>? tweetResult =
          addModEntry['item']?['content']?['tweetResult']?['result'];
      tweetResult ??=
          addModEntry['item']?['itemContent']?['tweet_results']?['result'];
      tweetResult ??=
          addModEntry['item']?['content']?['tweet_results']?['result'];
      // fromGraphqlJson handles the TweetWithVisibilityResults wrapper itself
      final id = tweetResult == null
          ? null
          : (tweetResult['rest_id'] ?? tweetResult['tweet']?['rest_id'])
                as String?;
      final tweet = _parseTweet(tweetResult);
      if (id != null && tweet != null) {
        chains.add(TweetChain(id: id, tweets: [tweet], isPinned: false));
      }
    }
  }

  //If we want to show pinned tweets, add them before the others that we already have
  if (pinnedTweets.isNotEmpty && showPinnedTweet) {
    chains.insertAll(0, pinnedChains);
  }
  return TweetStatus(
    chains: chains,
    cursorBottom: cursorBottom,
    cursorTop: cursorTop,
  );
}

/// Which parser [parseOffThread] should run. An enum instead of a callback:
/// only top-level references travel to another isolate.
enum ParseJob { tweetDetail, profile, follows, search, bookmarks }

/// Decodes [body] and runs the matching parser on a worker isolate, so pages
/// of a few hundred KB do not block the frame they arrive in. The locale is
/// loaded there too: tombstones and other localized bits are resolved while
/// parsing, and `L10n.current` would trip in a fresh isolate.
Future<T> parseOffThread<T>(String body, ParseJob job, {String? extra}) async {
  // Resolve the locale on the calling side: inside a fresh isolate,
  // Intl.getCurrentLocale() reports en_US, which would localize tombstones
  // and "user not found" errors in English on every worker-parsed page.
  final locale = Intl.getCurrentLocale();
  final result = await Isolate.run<Object>(() async {
    await L10n.load(Locale(locale));
    final json = jsonDecode(body) as Map<String, dynamic>;
    return switch (job) {
      ParseJob.tweetDetail => parseTweetDetail(json),
      ParseJob.profile => parseProfile(json, extra!),
      ParseJob.follows => parseFollows(json),
      ParseJob.search => parseSearchTimeline(json, product: extra!),
      ParseJob.bookmarks => parseBookmarkTimeline(json),
    };
  });

  return result as T;
}

/// The bookmarks timeline nests under its own key, unlike the other
/// unconversationed timelines.
TweetStatus parseBookmarkTimeline(Map<String, dynamic> body) {
  final timeline =
      body['data']?['bookmark_timeline_v2'] ??
      body['data']?['bookmark_timeline'];
  if (timeline is! Map<String, dynamic>) {
    return TweetStatus(chains: [], cursorBottom: null, cursorTop: null);
  }
  return createUnconversationedChainsGraphql(timeline, 'tweet', const [], true);
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
  // Resolve the locale here: a fresh isolate reports en_US until told, so
  // tombstones must load the app's locale captured on the calling side.
  final locale = Intl.getCurrentLocale();

  TweetStatus parse() {
    final result = jsonDecode(body) as Map<String, dynamic>;
    return conversationless
        ? createUnconversationedChains(
            result,
            tweetIndicator,
            pinnedTweets,
            mapToThreads,
            showPinnedTweet,
          )
        : createTimelineChains(
            result,
            tweetIndicator,
            pinnedTweets,
            mapToThreads,
            showPinnedTweet,
          );
  }

  // A tiny page (an empty one, usually) parses faster than an isolate spawns.
  final status = body.length < 50000
      ? parse()
      : await Isolate.run(() async {
          // Tombstones carry a localized message while parsing, and a fresh
          // isolate reports en_US until it is told the app's locale.
          await L10n.load(Locale(locale));
          return parse();
        });

  if (status.chains.length >= 5) return status;

  incrementTweetsCounter();
  if (getTweetsCounter() > 5) {
    return TweetStatus(
      chains: status.chains,
      cursorBottom: null,
      cursorTop: status.cursorTop,
    );
  }
  return status;
}

TweetStatus createTimelineChains(
  Map<String, dynamic> result,
  String tweetIndicator,
  List<String> pinnedTweets,
  bool mapToThreads,
  bool showPinnedTweet,
) {
  var instructions = List.from(
    result["data"]?["home"]?["home_timeline_urt"]?["instructions"] ?? const [],
  );
  var addEntriesInstructions = instructions.firstWhereOrNull(
    (e) => e['type'] == 'TimelineAddEntries',
  );
  if (addEntriesInstructions == null) {
    return TweetStatus(chains: [], cursorBottom: null, cursorTop: null);
  }
  var addPinnedTweetsInstructions = instructions.firstWhereOrNull(
    (e) => e['type'] == 'TimelinePinEntry',
  );
  var addEntries = List.from(addEntriesInstructions['entries']);
  var repEntries = List.from(
    instructions.where((e) => e['type'] == 'TimelineReplaceEntry'),
  );
  List addPinnedEntries = List<dynamic>.empty(growable: true);
  if (addPinnedTweetsInstructions != null) {
    addPinnedEntries.add(addPinnedTweetsInstructions['entry']);
  }

  String? cursorBottom = getCursor(
    addEntries,
    repEntries,
    'cursor-bottom',
    'Bottom',
  );
  String? cursorTop = getCursor(addEntries, repEntries, 'cursor-top', 'Top');
  var chains = createTweets(addEntries);
  // var debugTweets = json.encode(chains);
  //var debugTweets2 = json.encode(addEntries);
  var pinnedChains = createTweets(addPinnedEntries, true);

  //If we want to show pinned tweets, add them before the others that we already have
  if (pinnedTweets.isNotEmpty && showPinnedTweet) {
    chains.insertAll(0, pinnedChains);
  }

  return TweetStatus(
    chains: chains,
    cursorBottom: cursorBottom,
    cursorTop: cursorTop,
  );
}

Map<String, TweetWithCard> _createTweetsGraphql(
  String entryPrefix,
  List<dynamic> allTweets,
) {
  bool includeTweet(dynamic t) {
    // Exclude any items that aren't tweets
    if (t is! Map<String, dynamic>) return false;
    final entryId = t['entryId'];
    if (entryId is! String || !entryId.startsWith(entryPrefix)) {
      return false;
    }

    if (t['content']?['itemContent']?['promotedMetadata'] != null) {
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
      var elm = e['content']?['itemContent']?['tweet_results']?['result'];
      if (elm is Map<String, dynamic> &&
          elm['rest_id'] == null &&
          elm['tweet'] != null) {
        elm = elm['tweet'];
      }

      return elm;
    }),
  );

  final tweets = globalTweets
      .map(_parseTweet)
      .whereType<TweetWithCard>()
      .toList();

  return {
    for (var e in tweets)
      if (e.idStr != null) e.idStr!: e,
  };
}
