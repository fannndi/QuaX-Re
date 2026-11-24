part of 'client.dart';

TwitterError? _graphqlErrorIn(Map<String, dynamic> body) {
  final errors = body['errors'];
  if (errors is! List || errors.isEmpty) return null;
  final first = errors.first;
  final rawCode = first is Map ? first['code'] : null;
  final code = rawCode is num ? rawCode.toInt() : int.tryParse('$rawCode');
  final rawMessage = first is Map ? first['message'] : null;
  final message = rawMessage is String ? rawMessage : null;
  return TwitterError(
    code: code ?? 0,
    message: message ?? L10n.current.unknown_error,
    uri: '',
  );
}

void _validateGraphqlRoot(
  Map<String, dynamic> body, {
  required List<String> expectedRoot,
  required String uri,
}) {
  final error = _graphqlErrorIn(body);
  if (error != null) {
    throw TwitterError(code: error.code, message: error.message, uri: uri);
  }

  dynamic node = body;
  for (final segment in expectedRoot) {
    if (node is! Map<String, dynamic> ||
        node[segment] is! Map<String, dynamic>) {
      throw TwitterError(
        code: 0,
        message: L10n.current.unknown_error,
        uri: uri,
      );
    }
    node = node[segment];
  }
}

Map<String, dynamic> _decodeGraphqlBody(String body, {required String uri}) {
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw TwitterError(code: 0, message: L10n.current.unknown_error, uri: uri);
  }
  return decoded;
}

/// Reads a UserByScreenName or UserByRestId body. Separate from the request so
/// a recorded response can be replayed through the very same code.
Profile parseProfile(Map<String, dynamic> content, String uri) {
  final error = _graphqlErrorIn(content);
  if (error != null) {
    throw TwitterError(code: error.code, message: error.message, uri: uri);
  }

  final data = content['data'];
  if (data != null && data is! Map<String, dynamic>) {
    throw TwitterError(code: 0, message: L10n.current.unknown_error, uri: uri);
  }
  final user = data is Map<String, dynamic> ? data['user'] : null;
  if (user != null && user is! Map<String, dynamic>) {
    throw TwitterError(code: 0, message: L10n.current.unknown_error, uri: uri);
  }

  final result = user is Map<String, dynamic> ? user['result'] : null;
  if (result == null) {
    throw TwitterError(
      uri: uri,
      code: 50,
      message: L10n.current.user_not_found,
    );
  }
  if (result is! Map<String, dynamic>) {
    throw TwitterError(code: 0, message: L10n.current.unknown_error, uri: uri);
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

  final parsedUser = UserWithExtra.fromNonLegacyJson(result);

  return Profile(parsedUser, UserWithExtra.pinnedTweetIdsOf(result));
}

// GraphQL "Following"

/// Reads a Following or Followers body; both share the timeline shape.
PaginatedUsers parseFollows(Map<String, dynamic> body) {
  final users = PaginatedUsers()..users = [];
  dynamic instructions =
      body["data"]?["user"]?["result"]?["timeline"]?["timeline"]?["instructions"];
  final instructionList = instructions is List ? instructions : const [];
  final addEntries = instructionList
      .where((e) => e is Map && e['type'] == 'TimelineAddEntries')
      .expand((e) => e['entries'] is List ? e['entries'] as List : const [])
      .toList();
  final replaceEntries = instructionList
      .where((e) => e is Map && e['type'] == 'TimelineReplaceEntry')
      .toList();

  users.nextCursorStr = getCursor(
    addEntries,
    replaceEntries,
    'cursor-bottom',
    'Bottom',
  );
  users.previousCursorStr = getCursor(
    addEntries,
    replaceEntries,
    'cursor-top',
    'Top',
  );

  for (final entry in addEntries) {
    if (entry is! Map<String, dynamic>) continue;
    final userResult =
        entry["content"]?["itemContent"]?["user_results"]?["result"];
    if (userResult is! Map<String, dynamic>) continue;
    // The same parser the profile and search paths use. One malformed user must
    // not take the whole page down with it, exactly like _parseTweet below.
    try {
      users.users!.add(UserWithExtra.fromNonLegacyJson(userResult));
    } catch (e) {
      _QuackerTwitterClient.log.warning('Skipping an unparseable user: $e');
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

/// Unwraps a timeline entry into the tweet result it carries, or null.
///
/// The visibility wrapper and the `tweet` fallback are both shapes X serves for
/// the same thing: the wrapped object is what holds the id, and one endpoint puts
/// it one level deeper than the other. Callers then only have to ask for the id.
///
/// [item] is the node holding `itemContent` — a timeline entry's `content`, or a
/// media-grid item's `item`.
Map<String, dynamic>? _tweetResultOf(Map<String, dynamic> item) {
  final result = item["itemContent"]?["tweet_results"]?["result"];
  if (result is! Map<String, dynamic>) return null;

  if (result["__typename"] == "TweetWithVisibilityResults" &&
      result["tweet"] is Map<String, dynamic>) {
    return result["tweet"] as Map<String, dynamic>;
  }
  return result;
}

/// The id of a tweet result: the usual field, or the one the wrapped shape uses.
String? _tweetIdOf(Map<String, dynamic> result) {
  final id = result["rest_id"] ?? result["tweet"]?["rest_id"];
  return id is String ? id : null;
}

List<TweetChain> createTweetChains(List<dynamic> addEntries) {
  List<TweetChain> replies = [];

  for (var entry in addEntries) {
    final entryId = entry['entryId'];
    if (entryId is! String) continue;

    if (entryId.startsWith('tweet-')) {
      final content = entry['content'];
      if (content is! Map<String, dynamic>) continue;

      final tweetResult = content['itemContent']?['tweet_results']?['result'];

      // This may happen for tweets that x.com cannot open neither
      if (tweetResult is! Map<String, dynamic>) continue;

      final result = _tweetResultOf(content);
      final id = result == null ? null : _tweetIdOf(result);
      if (result != null && id != null) {
        final tweet = _parseTweet(result);
        if (tweet == null) continue;
        replies.add(TweetChain(id: id, tweets: [tweet], isPinned: false));
      } else {
        // Pass the real tombstone payload, not an empty map: X's own reason
        // ("This post was deleted", age-gated, ...) is in tweetResult['tombstone'],
        // and an empty map made every tombstone in a thread show the generic
        // "unavailable" text while the specific one sat unused in hand.
        final tombstone = tweetResult['tombstone'] ?? tweetResult;
        replies.add(
          TweetChain(
            id: entryId.substring(6),
            tweets: [TweetWithCard.tombstone(tombstone)],
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

      // TODO: This is missing tombstone support
      final items = entry['content']?['items'];
      for (final item
          in (items is List
              ? items.whereType<Map<String, dynamic>>()
              : const <Map<String, dynamic>>[])) {
        if (!isNotPromoted(item)) continue;
        final itemContent = item['item']?['itemContent'];
        if (itemContent?['itemType'] != 'TimelineTweet') continue;
        final tweet = _parseTweet(itemContent?['tweet_results']?['result']);
        if (tweet != null) {
          tweets.add(tweet);
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
      final content = entry['content'];
      if (content is! Map<String, dynamic>) continue;

      final result = _tweetResultOf(content);
      final id = result == null ? null : _tweetIdOf(result);
      if (result == null || id == null) continue;

      final tweet = _parseTweet(result);
      if (tweet == null) continue;

      replies.add(TweetChain(id: id, tweets: [tweet], isPinned: isPinned));
    } else if (entryId.startsWith('profile-grid-') ||
        entryId.startsWith('profile-photo-grid-')) {
      // We got a tweet queried from the media tab
      final items = entry['content']?['items'];
      for (final mediaTweet
          in (items is List
              ? items.whereType<Map<String, dynamic>>()
              : const <Map<String, dynamic>>[])) {
        final item = mediaTweet['item'];
        if (item is! Map<String, dynamic>) continue;

        final result = _tweetResultOf(item);
        final id = result == null ? null : _tweetIdOf(result);
        if (result == null || id == null) continue;

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

      // TODO: This is missing tombstone support
      final items = entry['content']?['items'];
      for (final item
          in (items is List
              ? items.whereType<Map<String, dynamic>>()
              : const <Map<String, dynamic>>[])) {
        final itemContent = item['item']?['itemContent'];
        if (itemContent?['itemType'] != 'TimelineTweet') continue;
        final tweet = _parseTweet(itemContent?['tweet_results']?['result']);
        if (tweet != null) {
          tweets.add(tweet);
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

  return createUnconversationedChainsGraphql(
    timeline,
    'tweet',
    const [],
    true,
    preserveServerOrder: true,
  );
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
  for (final item in moduleItems.whereType<Map>()) {
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

String? getCursor(
  List<dynamic> addEntries,
  List<dynamic> repEntries,
  String legacyType,
  String type,
) {
  // Every field below can be missing: X reorders, drops and renames entries
  // between deploys. One throw here would cost the whole page's pagination
  // rather than a single cursor, so each link in the chain is optional.
  String? entryId(dynamic entry) =>
      entry is Map ? entry['entryId']?.toString() : null;

  dynamic findEntry(
    Iterable<dynamic> entries,
    bool Function(dynamic entry) matches,
  ) {
    for (final entry in entries) {
      if (matches(entry)) return entry;
    }
    return null;
  }

  final dynamic cursorEntry;
  if (addEntries.any((e) => entryId(e)?.startsWith('cursor') ?? false)) {
    cursorEntry = findEntry(
      addEntries,
      (e) => entryId(e)?.contains(legacyType) ?? false,
    );
  } else {
    cursorEntry = findEntry(
      addEntries.where((e) => entryId(e)?.startsWith('sq-C') ?? false),
      (e) =>
          (e['content']?['operation']?['cursor']?['cursorType'] as String?)
              ?.toLowerCase() ==
          type.toLowerCase(),
    );
  }

  dynamic raw;
  if (cursorEntry is Map) {
    final content = cursorEntry['content'];
    if (content is! Map) {
      raw = null;
    } else if (content.containsKey('value')) {
      raw = content['value'];
    } else if (content.containsKey('operation')) {
      raw = content['operation']?['cursor']?['value'];
    } else {
      raw = content['itemContent']?['value'];
    }
  } else {
    // Look for a "replaceEntry" with the cursor.
    final replace = findEntry(
      repEntries,
      (e) =>
          e is Map &&
          (e['replaceEntry'] is Map
              ? ((e['replaceEntry']['entryIdToReplace'] as String?)
                        ?.toLowerCase()
                        .contains(type.toLowerCase()) ??
                    false)
              : ((e['entry']?['content']?['cursorType'] as String?)
                        ?.toLowerCase()
                        .contains(type.toLowerCase()) ??
                    false)),
    );

    raw = null;
    if (replace is Map) {
      if (replace['replaceEntry'] is Map) {
        raw =
            replace['replaceEntry']?['entry']?['content']?['operation']?['cursor']?['value'];
      } else {
        raw = replace['entry']?['content']?['value'];
      }
    }
  }

  return raw is String ? raw : null;
}

TweetStatus createUnconversationedChainsGraphql(
  Map<String, dynamic> result,
  String tweetIndicator,
  List<String> pinnedTweets,
  bool mapToThreads, {
  bool preserveServerOrder = false,
}) {
  // A timeline body X has reshaped arrives without the wrapper or the entries
  // this reads; an empty page is what it means, not a reason to throw.
  var instructions = List.from(result['timeline']?['instructions'] ?? const []);
  if (instructions.isEmpty ||
      !instructions.any((e) => e['type'] == 'TimelineAddEntries')) {
    return TweetStatus(chains: [], cursorBottom: null, cursorTop: null);
  }

  var addEntries = List.from(
    instructions.firstWhere(
          (e) => e['type'] == 'TimelineAddEntries',
        )['entries'] ??
        const [],
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

  var tweets = _createTweetsGraphql(tweetIndicator, addEntries);

  // First, get all the IDs of the tweets we need to display.
  String? entryRestId(dynamic e) {
    var result = e['content']?['itemContent']?['tweet_results']?['result'];
    return result?['rest_id'] ?? result?['tweet']?['rest_id'];
  }

  // Membership only: the order comes from the conversation map below. The old
  // sort read `sortIndex` as an int, but X sends it as a string, so every
  // comparison was 0 and the sorted list was discarded anyway.
  final tweetEntries = addEntries
      .where(
        (e) =>
            e['entryId']?.contains(tweetIndicator) == true &&
            entryRestId(e) != null,
      )
      .map(entryRestId)
      .whereType<String>()
      .toSet();

  Map<String, List<TweetWithCard>> conversations = tweets.values
      .where((e) => tweetEntries.contains(e.idStr))
      .groupBy((e) {
        // TODO: I don't think a flag is the right way to handle this
        if (mapToThreads) {
          // Then group the tweets-to-display by their conversation ID
          return e.conversationIdStr;
        }

        return e.idStr;
      })
      .cast<String, List<TweetWithCard>>();

  List<TweetChain> chains = [];

  // Search and Bookmarks are explicitly ordered by X. Other timelines retain
  // their historical newest-first grouping.
  final orderedConversations = preserveServerOrder
      ? conversations.entries
      : conversations.entries.sorted((a, b) => b.key.compareTo(a.key));
  for (var conversation in orderedConversations) {
    final chainTweets =
        (preserveServerOrder
                ? conversation.value
                : conversation.value.sorted(
                    (a, b) => a.idStr!.compareTo(b.idStr!),
                  ))
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
  bool showPinnedTweet,
  int Function() getTweetsCounter,
  void Function() increaseTweetCounter,
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
  return TweetStatus(
    chains: chains,
    cursorBottom: cursorBottom,
    cursorTop: cursorTop,
  );
}

/// Which parser [parseOffThread] should run. An enum instead of a callback:
/// only top-level references travel to another isolate.
enum ParseJob { tweetDetail, profile, follows, search, searchUsers, bookmarks }

enum _ParseMode { offThread, chains }

class _ParseRequest {
  const _ParseRequest({
    required this.mode,
    required this.body,
    this.job,
    this.extra,
    this.expectedRoot = const [],
    this.conversationless = false,
    this.tweetIndicator = 'tweet',
    this.pinnedTweets = const [],
    this.showPinnedTweet = false,
    this.workerSendPort,
  });

  final _ParseMode mode;
  final String body;
  final ParseJob? job;
  final String? extra;
  final List<String> expectedRoot;
  final bool conversationless;
  final String tweetIndicator;
  final List<String> pinnedTweets;
  final bool showPinnedTweet;
  final SendPort? workerSendPort;
}

/// A parse that never comes back must not leave an isolate behind. Unlike
/// `Isolate.run().timeout`, this owns the isolate handle and kills it on expiry.
const _parseTimeout = Duration(seconds: 30);

Future<Object> _parseRequest(_ParseRequest request) async {
  await L10n.load(const Locale('en'));
  final uri = request.extra ?? '';
  final json = _decodeGraphqlBody(request.body, uri: uri);

  if (request.mode == _ParseMode.chains) {
    _validateGraphqlRoot(json, expectedRoot: request.expectedRoot, uri: uri);
    return request.conversationless
        ? createUnconversationedChains(
            json,
            request.tweetIndicator,
            request.pinnedTweets,
            request.showPinnedTweet,
            () => 0,
            () {},
          )
        : createTimelineChains(
            json,
            request.tweetIndicator,
            request.pinnedTweets,
            request.showPinnedTweet,
            () => 0,
            () {},
          );
  }

  switch (request.job) {
    case ParseJob.tweetDetail:
      _validateGraphqlRoot(
        json,
        expectedRoot: const [
          'data',
          'threaded_conversation_with_injections_v2',
        ],
        uri: uri,
      );
      return parseTweetDetail(json);
    case ParseJob.profile:
      return parseProfile(json, request.extra!);
    case ParseJob.follows:
      _validateGraphqlRoot(
        json,
        expectedRoot: const ['data', 'user', 'result', 'timeline', 'timeline'],
        uri: uri,
      );
      return parseFollows(json);
    case ParseJob.search:
      _validateGraphqlRoot(
        json,
        expectedRoot: const ['data', 'search_by_raw_query', 'search_timeline'],
        uri: uri,
      );
      return parseSearchTimeline(json, product: request.extra!);
    case ParseJob.searchUsers:
      _validateGraphqlRoot(
        json,
        expectedRoot: const ['data', 'search_by_raw_query', 'search_timeline'],
        uri: uri,
      );
      return parseSearchUsers(json);
    case ParseJob.bookmarks:
      final error = _graphqlErrorIn(json);
      if (error != null) {
        throw TwitterError(code: error.code, message: error.message, uri: uri);
      }
      if (json['data']?['bookmark_timeline_v2'] is Map<String, dynamic>) {
        return parseBookmarkTimeline(json);
      }
      _validateGraphqlRoot(
        json,
        expectedRoot: const ['data', 'bookmark_timeline'],
        uri: uri,
      );
      return parseBookmarkTimeline(json);
    case null:
      throw StateError('A parse request needs a job');
  }
}

void _parseWorker(_ParseRequest request) {
  final send = request.workerSendPort!;
  void sendFailure(Object error, StackTrace stackTrace) {
    if (error is TwitterError) {
      send.send({
        'ok': false,
        'twitterError': {
          'code': error.code,
          'message': error.message,
          'uri': error.uri,
        },
        'stackTrace': stackTrace.toString(),
      });
    } else {
      send.send({
        'ok': false,
        'error': error,
        'stackTrace': stackTrace.toString(),
      });
    }
  }

  runZonedGuarded(() {
    unawaited(
      _parseRequest(request).then(
        (value) => send.send({'ok': true, 'value': value}),
        onError: sendFailure,
      ),
    );
  }, sendFailure);
}

Future<T> _runParseIsolate<T>(_ParseRequest request, Duration timeout) async {
  final port = ReceivePort();
  final completer = Completer<T>();
  Timer? timer;
  late final Isolate isolate;

  void finish(void Function() complete) {
    timer?.cancel();
    if (completer.isCompleted) return;
    port.close();
    complete();
  }

  try {
    isolate = await Isolate.spawn(
      _parseWorker,
      _ParseRequest(
        mode: request.mode,
        body: request.body,
        job: request.job,
        extra: request.extra,
        expectedRoot: request.expectedRoot,
        conversationless: request.conversationless,
        tweetIndicator: request.tweetIndicator,
        pinnedTweets: request.pinnedTweets,
        showPinnedTweet: request.showPinnedTweet,
        workerSendPort: port.sendPort,
      ),
      onError: port.sendPort,
    );
  } catch (error, stackTrace) {
    port.close();
    Error.throwWithStackTrace(error, stackTrace);
  }

  timer = Timer(timeout, () {
    if (completer.isCompleted) return;
    isolate.kill(priority: Isolate.immediate);
    finish(
      () => completer.completeError(
        TimeoutException('Timeline parsing timed out'),
      ),
    );
  });

  port.listen((message) {
    if (message is List && message.length == 2) {
      finish(
        () => completer.completeError(
          StateError('Parse isolate failed: ${message.join('\n')}'),
          StackTrace.current,
        ),
      );
      return;
    }
    if (message is! Map) {
      finish(
        () => completer.completeError(
          StateError('Parse isolate exited without a result'),
        ),
      );
      return;
    }
    timer?.cancel();
    if (message['ok'] == true) {
      finish(() => completer.complete(message['value'] as T));
    } else {
      final twitterError = message['twitterError'];
      final error = twitterError is Map
          ? TwitterError(
              code: twitterError['code'] as int,
              message: twitterError['message'] as String,
              uri: twitterError['uri'] as String,
            )
          : message['error'] ?? StateError('Parse isolate failed');
      final stackTrace = StackTrace.fromString(
        message['stackTrace']?.toString() ?? '',
      );
      finish(() => completer.completeError(error, stackTrace));
    }
  });

  return completer.future;
}

/// Decodes [body] and runs the matching parser on a worker isolate, so pages
/// of a few hundred KB do not block the frame they arrive on. The locale is
/// loaded there too: tombstones and other localized bits are resolved while
/// parsing, and `L10n.current` would trip in a fresh isolate.
Future<T> parseOffThread<T>(
  String body,
  ParseJob job, {
  String? extra,
  Duration parseTimeout = _parseTimeout,
}) async {
  final result = await _runParseIsolate<Object>(
    _ParseRequest(
      mode: _ParseMode.offThread,
      body: body,
      job: job,
      extra: extra,
    ),
    parseTimeout,
  );
  return result as T;
}

/// The user entries and bottom cursor of a SearchTimeline answer for
/// `product: People`.
UserSearchPage parseSearchUsers(Map<String, dynamic> body) {
  final rawInstructions =
      body['data']?['search_by_raw_query']?['search_timeline']?['timeline']?['instructions'];
  final instructions = rawInstructions is List ? rawInstructions : const [];
  final addEntries = instructions
      .where((e) => e is Map && e['type'] == 'TimelineAddEntries')
      .expand((e) => e['entries'] is List ? e['entries'] as List : const [])
      .toList();
  final replaceEntries = instructions
      .where((e) => e is Map && e['type'] == 'TimelineReplaceEntry')
      .toList();
  final nextCursor = getCursor(
    addEntries,
    replaceEntries,
    'cursor-bottom',
    'Bottom',
  );

  final users = <UserWithExtra>[];
  for (final entry in addEntries) {
    if (entry is! Map<String, dynamic>) continue;
    if (!(entry['entryId']?.startsWith('user-') ?? false)) continue;
    final result = entry['content']?['itemContent']?['user_results']?['result'];
    if (result is! Map<String, dynamic> || result['rest_id'] == null) continue;
    try {
      users.add(UserWithExtra.fromNonLegacyJson(result));
    } catch (e) {
      // One changed user shape should cost that row, not the People page.
      _QuackerTwitterClient.log.warning(
        'Skipping an unparseable search user: $e',
      );
    }
  }
  return (users: users, nextCursor: nextCursor);
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
  return createUnconversationedChainsGraphql(
    timeline,
    'tweet',
    const [],
    true,
    preserveServerOrder: true,
  );
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
  required bool showPinnedTweet,
  required int Function() getTweetsCounter,
  required void Function() incrementTweetsCounter,
  void Function()? resetTweetsCounter,
  List<String>? expectedRoot,
  Duration parseTimeout = _parseTimeout,
}) async {
  final root =
      expectedRoot ??
      (conversationless
          ? const ['data', 'user', 'result', 'timeline']
          : const ['data', 'home', 'home_timeline_urt']);
  TweetStatus parse() {
    final result = _decodeGraphqlBody(body, uri: '');
    _validateGraphqlRoot(result, expectedRoot: root, uri: '');
    return conversationless
        ? createUnconversationedChains(
            result,
            tweetIndicator,
            pinnedTweets,
            showPinnedTweet,
            () => 0,
            () {},
          )
        : createTimelineChains(
            result,
            tweetIndicator,
            pinnedTweets,
            showPinnedTweet,
            () => 0,
            () {},
          );
  }

  // A tiny page (an empty one, usually) parses faster than an isolate spawns.
  final status = body.length < 50000
      ? parse()
      : await _runParseIsolate<TweetStatus>(
          _ParseRequest(
            mode: _ParseMode.chains,
            body: body,
            expectedRoot: root,
            conversationless: conversationless,
            tweetIndicator: tweetIndicator,
            pinnedTweets: pinnedTweets,
            showPinnedTweet: showPinnedTweet,
          ),
          parseTimeout,
        );

  if (status.chains.length >= 5) {
    // A healthy page resets the count. Without this the counter only ever grew:
    // after six near-empty pages it stayed above the threshold forever, and the
    // feed could never page again until its widget was rebuilt — even once X
    // went back to serving full pages.
    resetTweetsCounter?.call();
    return status;
  }

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
  bool showPinnedTweet,
  int Function() getTweetsCounter,
  void Function() increaseTweetCounter,
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
  var addEntries = List.from(addEntriesInstructions['entries'] ?? const []);
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
    if (t is! Map) return false;

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
