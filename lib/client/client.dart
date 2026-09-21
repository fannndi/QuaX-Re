import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui' show Locale;

import 'package:dart_twitter_api/src/utils/date_utils.dart';
import 'package:dart_twitter_api/twitter_api.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:quax/catcher/exceptions.dart';
import 'package:quax/client/account_selector.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/client_regular_account.dart';
import 'package:quax/client/client_unauthenticated.dart';
import 'package:quax/client/headers.dart';
import 'package:quax/client/rate_limit_tracker.dart';
import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/profile/profile_model.dart';
import 'package:quax/article/article.dart';
import 'package:quax/user.dart';
import 'package:quax/utils/iterables.dart';
import 'package:quax/utils/timeline_cache.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

part 'client_parsing.dart';
part 'client_models.dart';

const Duration _defaultTimeout = Duration(seconds: 30);

class _QuackerTwitterClient extends TwitterClient {
  static final log = Logger('_QuackerTwitterClient');

  _QuackerTwitterClient() : super(consumerKey: '', consumerSecret: '', token: '', secret: '');

  // Identical requests flying at the same time (two tabs refreshing, a soft
  // refresh racing the pager) share one response instead of burning another
  // rate-limit slot.
  static final Map<String, Future<http.Response>> _inflight = {};

  @override
  Future<http.Response> get(Uri uri, {Map<String, String>? headers, Duration? timeout}) {
    final key = uri.toString();
    final running = _inflight[key];
    if (running != null) return running;

    late final Future<http.Response> future;
    future = fetch(uri, headers: headers).timeout(timeout ?? _defaultTimeout).then<http.Response>((response) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response;
      } else {
        return Future.error(HttpException(response));
      }
    }).whenComplete(() {
      if (identical(_inflight[key], future)) _inflight.remove(key);
    });

    _inflight[key] = future;
    return future;
  }

  /// Authenticated JSON POST for the GraphQL operations X now serves as POST
  /// (HomeTimeline, HomeLatestTimeline). Mirrors [get]'s status handling and
  /// request coalescing. Static because `TwitterApi.client` is typed as the
  /// package's AbstractTwitterClient, which has no such helper.
  static Future<http.Response> postJson(Uri uri,
      {Map<String, String>? headers, required String body, Duration? timeout}) {
    final key = '${uri.toString()}|$body';
    final running = _inflight[key];
    if (running != null) return running;

    late final Future<http.Response> future;
    future = fetch(uri, headers: headers, body: body)
        .timeout(timeout ?? _defaultTimeout)
        .then<http.Response>((response) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response;
      } else {
        return Future.error(HttpException(response));
      }
    }).whenComplete(() {
      if (identical(_inflight[key], future)) _inflight.remove(key);
    });

    _inflight[key] = future;
    return future;
  }

  /// Tries accounts (healthy ones first, then flagged ones as a fallback),
  /// retrying on another account when one returns a 429 (rate-limited for that
  /// endpoint, tracked in memory), a 404 (retried once, then surfaced) or a 401
  /// (session explicitly rejected: counted as broken auth). Rate limits are
  /// per-endpoint, so a 429 on one endpoint never blocks another.
  ///
  /// A real request is always attempted before any error: with accounts, each is
  /// tried; with none, an unauthenticated (guest) request is sent. Errors surface
  /// only from actual responses: [RateLimitedException] when every account was
  /// rate-limited on the endpoint, [NoWorkingAccountException] when they all
  /// returned 404, and [NoAccountAvailableException] only when there is no account
  /// and the guest request also failed. Network-level failures (socket, timeout,
  /// TLS) are absorbed once per fetch with a short pause, since they never
  /// reached X and are no account's fault; a second one is surfaced as-is.
  static Future<http.Response> fetch(Uri uri, {Map<String, String>? headers, String? body}) async {
    final endpoint = uri.path;
    final now = DateTime.now();
    final accounts = await getAccounts();
    final selector = AccountSelector(accounts, now,
        isRateLimited: (a) => RateLimitTracker.isLimited(a.id, endpoint, now));
    final tried = <String>{};
    var authFailures = 0;
    var networkFailures = 0;
    http.Response? lastError;
    Object? lastNetworkError;
    StackTrace? lastNetworkStackTrace;

    while (true) {
      final account = selector.pick(exclude: tried);
      if (account == null) {
        break;
      }
      tried.add(account.id);

      final authHeader = json.decode(account.authHeader);
      http.Response response;
      try {
        response =
            await XRegularAccount().fetch(uri, headers: headers, body: body, log: log, authHeader: authHeader);
      } on Exception catch (e, st) {
        lastNetworkError = e;
        lastNetworkStackTrace = st;
        if (++networkFailures >= 2) {
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
        tried.remove(account.id); // the network failed, not the account: it may be retried
        continue;
      }
      final code = response.statusCode;

      if (code < 200 || code >= 300) {
        // Surfaced in the Android log: the fastest way to spot a rotated
        // queryId (404) or a shape change (400) without a debugger.
        if (kDebugMode) debugPrint('QuaX fetch $code ${uri.path}');
      }

      if (code >= 200 && code < 300) {
        if (response.headers['x-rate-limit-remaining'] == '0') {
          // That was the last call allowed on this endpoint for the window:
          // flag now so the next request rotates instead of eating a 429.
          RateLimitTracker.flag(account.id, endpoint, _resetFromHeaders(response));
        } else {
          RateLimitTracker.clear(account.id, endpoint);
        }
        if (!account.isClean) {
          await recordAccountSuccess(account.id);
        }
        return response;
      }
      lastError = response;
      if (code == 429) {
        RateLimitTracker.flag(account.id, endpoint, _resetFromHeaders(response));
        continue;
      }
      if (code == 404 || code == 401) {
        // The keys behind x-client-transaction-id rotate with X's deploys, and
        // a stale generator answers 404 — let the header cache self-heal.
        TwitterHeaders.invalidateIfStale();
        // A 404 on a queryId-pinned GraphQL path usually means X rotated the
        // endpoint's queryId, not that this account's auth is broken — don't
        // taint account health for it (see getHomeLatestTimeline). A 401 is X
        // rejecting the session, so it counts as broken auth.
        final staleQueryId = code == 404 && uri.path.contains('/i/api/graphql/');
        if (!staleQueryId) {
          await recordNotFound(account.id);
        }
        if (++authFailures >= 2) {
          break; // tried enough accounts; surface the outcome below
        }
        continue;
      }
      return response; // other errors surfaced immediately
    }

    if (lastError == null && lastNetworkError != null) {
      Error.throwWithStackTrace(lastNetworkError, lastNetworkStackTrace!);
    }
    if (tried.isEmpty) {
      // A POST body is private data; no account means no request.
      if (body != null) {
        throw NoAccountAvailableException();
      }
      // No account at all: still attempt an unauthenticated (guest) request so we
      // never error before sending one. Only invite to add an account if it fails.
      final guest = await fetchUnauthenticated(uri, headers: headers, log: log);
      if (guest.statusCode >= 200 && guest.statusCode < 300) {
        return guest;
      }
      throw NoAccountAvailableException();
    }
    if (lastError?.statusCode == 429) {
      throw RateLimitedException(); // every account was rate-limited on this endpoint
    }
    if (lastError?.statusCode == 404) {
      throw NoWorkingAccountException(); // accounts tried all returned 404 (likely broken auth)
    }
    return lastError!; // surface the real error
  }

  static DateTime _resetFromHeaders(http.Response response) {
    final reset = response.headers['x-rate-limit-reset']; // epoch seconds
    if (reset != null) {
      return DateTime.fromMillisecondsSinceEpoch(int.parse(reset) * 1000);
    }
    return DateTime.now().add(rateLimitFallback);
  }
}

class Twitter {
  static final TwitterApi _twitterApi = TwitterApi(client: _QuackerTwitterClient());

  static const Map<String, bool> _timelineFeatures = {
    "articles_preview_enabled": true,
    "c9s_tweet_anatomy_moderator_badge_enabled": true,
    "communities_web_enable_tweet_community_results_fetch": true,
    "content_disclosure_ai_generated_indicator_enabled": true,
    "content_disclosure_indicator_enabled": true,
    "creator_subscriptions_tweet_preview_api_enabled": true,
    "freedom_of_speech_not_reach_fetch_enabled": true,
    "graphql_is_translatable_rweb_tweet_is_translatable_enabled": true,
    "longform_notetweets_consumption_enabled": true,
    "longform_notetweets_inline_media_enabled": false,
    "longform_notetweets_rich_text_read_enabled": true,
    "post_ctas_fetch_enabled": false,
    "premium_content_api_read_enabled": false,
    "profile_label_improvements_pcf_label_in_post_enabled": true,
    "responsive_web_edit_tweet_api_enabled": true,
    "responsive_web_enhance_cards_enabled": false,
    "responsive_web_graphql_timeline_navigation_enabled": true,
    "responsive_web_grok_analysis_button_from_backend": true,
    "responsive_web_grok_analyze_button_fetch_trends_enabled": false,
    "responsive_web_grok_analyze_post_followups_enabled": true,
    "responsive_web_grok_annotations_enabled": true,
    "responsive_web_grok_community_note_auto_translation_is_enabled": true,
    "responsive_web_grok_image_annotation_enabled": true,
    "responsive_web_grok_imagine_annotation_enabled": true,
    "responsive_web_grok_share_attachment_enabled": true,
    "responsive_web_grok_show_grok_translated_post": true,
    "responsive_web_jetfuel_frame": true,
    "responsive_web_profile_redirect_enabled": true,
    "responsive_web_twitter_article_tweet_consumption_enabled": true,
    "rweb_cashtags_composer_attachment_enabled": true,
    "rweb_cashtags_enabled": true,
    "rweb_conversational_replies_downvote_enabled": false,
    "rweb_tipjar_consumption_enabled": false,
    "rweb_video_screen_enabled": false,
    "standardized_nudges_misinfo": true,
    "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": true,
    "verified_phone_label_enabled": false,
    "view_counts_everywhere_api_enabled": true,
  };

  static const Map<String, bool> _profileFeatures = {
    "creator_subscriptions_tweet_preview_api_enabled": true,
    "hidden_profile_subscriptions_enabled": true,
    "highlights_tweets_tab_ui_enabled": true,
    "profile_label_improvements_pcf_label_in_post_enabled": true,
    "responsive_web_graphql_timeline_navigation_enabled": true,
    "responsive_web_profile_redirect_enabled": true,
    "responsive_web_twitter_article_notes_tab_enabled": true,
    "rweb_tipjar_consumption_enabled": false,
    "subscriptions_feature_can_gift_premium": true,
    "subscriptions_verification_info_is_identity_verified_enabled": true,
    "subscriptions_verification_info_verified_since_enabled": true,
    "verified_phone_label_enabled": false,
  };

  static Future<Profile> getProfileById(String id) async {
    var uri = Uri.https('twitter.com', '/i/api/graphql/XIpMDIi_YoVzXeoON-cfAQ/UserByRestId', {
      'variables': jsonEncode({
        'userId': id,
        'withHighlightedLabel': true,
        'withSafetyModeUserFields': true,
        'withSuperFollowsUserFields': true,
      }),
      'features': jsonEncode(_profileFeatures),
    });

    return _getProfile(uri);
  }

  static Future<Profile> getProfileByScreenName(String screenName) async {
    if (screenName.startsWith('@')) {
      screenName = screenName.substring(1);
    }
    var uri = Uri.https('twitter.com', '/i/api/graphql/IGgvgiOx4QZndDHuD3x9TQ/UserByScreenName', {
      'variables': jsonEncode({'screen_name': screenName, "withSafetyModeUserFields": true}),
      'features': jsonEncode(_profileFeatures),
    });

    return _getProfile(uri);
  }

  static Future<Profile> _getProfile(Uri uri) async {
    var response = await _twitterApi.client.get(uri);
    return parseOffThread<Profile>(response.body, ParseJob.profile, extra: uri.toString());
  }

  static Future<PaginatedUsers> friendsList(String userId, int count, {String? cursor}) => _graphqlFollows(
        userId,
        count,
        cursor: cursor,
        queryId: 'F42cDX8PDFxkbjjq6JrM2w',
        operation: 'Following',
      );

  // GraphQL "Followers"
  static Future<PaginatedUsers> followersList(String userId, int count, {String? cursor}) => _graphqlFollows(
        userId,
        count,
        cursor: cursor,
        queryId: '_orfRBQae57vylFPH0Huhg',
        operation: 'Followers',
      );

  // Shared cursor-paginated GraphQL user-list fetch (Following / Followers share
  // the same timeline shape; only the query id, operation and feature flags differ).
  static Future<PaginatedUsers> _graphqlFollows(
    String userId,
    int count, {
    String? cursor,
    required String queryId,
    required String operation,
  }) async {
    final uri = Uri.https('x.com', '/i/api/graphql/$queryId/$operation', {
      "variables": jsonEncode({
        "userId": userId,
        "count": count,
        "cursor": ?cursor,
        "includePromotedContent": false,
        "withGrokTranslatedBio": false,
      }),
      "features": jsonEncode(_timelineFeatures),
    });

    return _twitterApi.client
        .get(uri)
        .then((response) => parseOffThread<PaginatedUsers>(response.body, ParseJob.follows));
  }

  static Future<Follows> getProfileFollows(
    String screenName,
    String type, {
    String? cursor,
    int? count = 200,
    String? id,
  }) async {
    id ??= (await getProfileByScreenName(screenName)).user.idStr;
    var response = type == 'following'
        ? await friendsList(id!, count!, cursor: cursor)
        : await followersList(id!, count!, cursor: cursor);

    return Follows(
      cursorBottom: response.nextCursorStr,
      cursorTop: response.previousCursorStr,
      users: response.users?.map((e) => UserWithExtra.fromJson(e.toJson())).toList() ?? [],
    );
  }

  static Future<TweetStatus> getTweet(String id, {String? cursor}) async {
    Map<String, dynamic> defaultParam = {
      "variables": jsonEncode({
        "focalTweetId": "0",
        "with_rux_injections": false,
        "rankingMode": "Relevance",
        "includePromotedContent": true,
        "withCommunity": true,
        "withQuickPromoteEligibilityTweetFields": true,
        "withBirdwatchNotes": true,
        "withVoice": true,
      }),
      "features": jsonEncode(_timelineFeatures),
      "fieldToggles": jsonEncode({
        "withArticleRichContentState": true,
        "withArticlePlainText": false,
        "withArticleSummaryText": false,
        "withArticleVoiceOver": false,
        "withGrokAnalyze": false,
        "withDisallowedReplyControls": false,
      }),
    };

    Map<String, dynamic> variables = json.decode(defaultParam["variables"].toString());
    variables["focalTweetId"] = id;

    if (cursor != null) {
      variables['cursor'] = cursor;
    }

    defaultParam["variables"] = json.encode(variables);

    final cacheKey = TimelineCache.keyFor('thread.$id');
    try {
      var response = await _twitterApi.client.get(
        Uri.https('x.com', '/i/api/graphql/oCon7R-cgWRFy6EfZjaKfg/TweetDetail', defaultParam),
      );
      if (cursor == null) {
        // The opened conversation is now readable offline, replies included.
        unawaited(TimelineCache.write(cacheKey, response.body));
      }
      return await parseOffThread<TweetStatus>(response.body, ParseJob.tweetDetail);
    } catch (e) {
      // Offline (or X unreachable): serve the stored conversation, if any.
      if (cursor == null) {
        final cached = await TimelineCache.read(cacheKey);
        if (cached != null) {
          return await parseOffThread<TweetStatus>(cached, ParseJob.tweetDetail);
        }
      }
      rethrow;
    }
  }

  static Future<TweetStatus> searchTweets(
    String query, {
    int limit = 20,
    String? cursor,
    String product = "Latest",
  }) async {
    var variables = {
      "rawQuery": query,
      "count": limit.toString(),
      "querySource": "typed_query",
      "product": product,
      "withGrokTranslatedBio": true,
      "withQuickPromoteEligibilityTweetFields": false,
    };


    if (cursor != null) {
      variables['cursor'] = cursor;
    }

    var uri = Uri.https('x.com', '/i/api/graphql/Yw6L66Pw54NHKuq4Dp7b4Q/SearchTimeline', {
      'variables': jsonEncode(variables),
      'features': jsonEncode(_timelineFeatures),
    });

    var response = await _twitterApi.client.get(uri);
    return parseOffThread<TweetStatus>(response.body, ParseJob.search, extra: product);
  }

  static Future<List<UserWithExtra>> searchUsers(String query, {int limit = 25, String? cursor}) async {
    var variables = {
      "rawQuery": query,
      "count": limit.toString(),
      "querySource": "typed_query",
      "product": 'People',
      "withDownvotePerspective": false,
      "withReactionsMetadata": false,
      "withReactionsPerspective": false,
    };


    if (cursor != null) {
      variables['cursor'] = cursor;
    }

    var uri = Uri.https('twitter.com', '/i/api/graphql/Yw6L66Pw54NHKuq4Dp7b4Q/SearchTimeline', {
      'variables': jsonEncode(variables),
      'features': jsonEncode(_timelineFeatures),
    });

    var response = await _twitterApi.client.get(uri);
    if (response.body.isEmpty) {
      return [];
    }

    var result = json.decode(response.body);
    if (result.isEmpty) {
      return [];
    }

    List instructions = List.from(
      result?['data']?['search_by_raw_query']?['search_timeline']?['timeline']?['instructions'] ?? [],
    );
    if (instructions.isEmpty) {
      return [];
    }
    List addEntries = List.from(
      instructions.firstWhere((e) => e['type'] == 'TimelineAddEntries', orElse: () => null)?['entries'] ?? [],
    );
    if (addEntries.isEmpty) {
      return [];
    }

    return addEntries
        .where((entry) => entry['entryId']?.startsWith('user-'))
        .map((entry) => entry['content']?['itemContent']?['user_results']?['result'])
        .whereType<Map<String, dynamic>>()
        .where((result) => result['rest_id'] != null)
        .map(UserWithExtra.fromNonLegacyJson)
        .toList();
  }

  /// The For You (ranked) home timeline. The variables mirror what x.com
  /// actually sends (see the recorded fixture): crucially `requestContext:
  /// "launch"` on the first page — without it X keeps serving a stale slice of
  /// the ranked feed. [seenTweetIds] carries what is already on screen so a
  /// refresh comes back with genuinely different posts instead of a repeat.
  static Future<TweetStatus> getTimelineTweets(
    String id,
    String type, {
    List<String>? pinnedTweets,
    List<String>? seenTweetIds,
    int count = 10,
    String? cursor,
    bool includeReplies = true,
    bool includeRetweets = true,
    required int Function() getTweetsCounter,
    required void Function() incrementTweetsCounter,
  }) async {
    final variables = <String, dynamic>{
      "count": count,
      "includePromotedContent": true,
      "latestControlAvailable": true,
      "withCommunity": true,
      if (cursor == null) "requestContext": "launch" else "cursor": cursor,
      if (cursor == null && seenTweetIds != null && seenTweetIds.isNotEmpty) "seenTweetIds": seenTweetIds,
    };

    // X serves HomeTimeline as a POST now; the old GET queryId (wp06oo3f…)
    // answered from a frozen archive, which is why For You never moved.
    final response = await _QuackerTwitterClient.postJson(
      Uri.https('x.com', '/i/api/graphql/7zlnp2TxC044W4C1ZUJMHw/HomeTimeline'),
      body: jsonEncode({'variables': variables, 'features': _timelineFeatures}),
    );
    // Pinned posts only belong on the first page.
    return parseChainsOnIsolate(
      response.body,
      conversationless: false,
      tweetIndicator: 'tweet',
      pinnedTweets: pinnedTweets ?? [],
      mapToThreads: includeReplies == false,
      includeReplies: includeReplies,
      showPinnedTweet: cursor == null,
      getTweetsCounter: getTweetsCounter,
      incrementTweetsCounter: incrementTweetsCounter,
    );
  }

  /// Chronological "Following" home timeline, served by X's HomeLatestTimeline
  /// endpoint. Its body has the same shape as HomeTimeline's
  /// (data.home.home_timeline_urt.instructions), so the parsing is shared.
  /// X rotates queryIds at each deploy: this one is tracked by the community at
  /// https://github.com/fa0311/twitter-openapi — a 404 on this endpoint usually
  /// means it changed and the id below needs updating (capture the new one from
  /// the network tab of a x.com/home "Following" tab visit, or from that repo).
  static Future<TweetStatus> getHomeLatestTimeline({
    int count = 20,
    String? cursor,
    required int Function() getTweetsCounter,
    required void Function() incrementTweetsCounter,
  }) async {
    final variables = <String, dynamic>{
      "count": count,
      "includePromotedContent": true,
      "latestControlAvailable": true,
      if (cursor == null) "requestContext": "launch" else "cursor": cursor,
    };

    // HomeLatestTimeline is a POST too; the old GET shape is what X keeps in
    // its compatibility cache, which is why Following could look frozen.
    final response = await _QuackerTwitterClient.postJson(
      Uri.https('x.com', '/i/api/graphql/0dateTVgvXjpkf7kyBZy0g/HomeLatestTimeline'),
      body: jsonEncode({'variables': variables, 'features': _timelineFeatures}),
    );
    return parseChainsOnIsolate(
      response.body,
      conversationless: false,
      tweetIndicator: 'tweet',
      pinnedTweets: const [],
      mapToThreads: true,
      includeReplies: false,
      showPinnedTweet: false,
      getTweetsCounter: getTweetsCounter,
      incrementTweetsCounter: incrementTweetsCounter,
    );
  }

  /// The account notifications timeline, served by X's NotificationsTimeline
  /// endpoint (the x.com/web "Notifications" page). Each entry is either an
  /// aggregated notification (likes, replies, bell-subscribed posts…) or a
  /// plain embedded tweet, under
  /// data.viewer_v2.user_results.result.notification_timeline. The queryId
  /// below comes from the recorded fixture (see tool/record) — refresh the
  /// fixture there when a 404 appears.
  static Future<NotificationsPage> getNotificationsTimeline({int count = 20, String? cursor}) async {
    var variables = {
      "timeline_type": "All",
      "count": count,
      if (cursor != null) "cursor": cursor,
    };

    var response = await _twitterApi.client.get(
      Uri.https('x.com', '/i/api/graphql/gzC0OYBCnfdYS4M4Gue7BA/NotificationsTimeline', {
        'variables': jsonEncode(variables),
        'features': jsonEncode(_timelineFeatures),
      }),
    );
    return parseNotifications(json.decode(response.body) as Map<String, dynamic>);
  }

  /// The posts an account liked, served by X's Likes endpoint — usable for the
  /// account the request runs as (X keeps likes private otherwise). The body
  /// has the usual user-timeline shape, so the shared parser reads it. The
  /// queryId is community-tracked (fa0311/twitter-openapi); refresh it when a
  /// 404 shows up.
  static Future<TweetStatus> getLikes(
    String userId, {
    int count = 20,
    String? cursor,
    required int Function() getTweetsCounter,
    required void Function() incrementTweetsCounter,
  }) async {
    var variables = {
      "userId": userId,
      "count": count,
      "includePromotedContent": false,
      "withClientEventToken": false,
      "withBirdwatchNotes": false,
      "withVoice": true,
    };
    if (cursor != null) {
      variables['cursor'] = cursor;
    }

    var response = await _twitterApi.client.get(
      Uri.https('x.com', '/i/api/graphql/rk2aeVVvKsyUdG3jf5uiLw/Likes', {
        'variables': jsonEncode(variables),
        'features': jsonEncode(_timelineFeatures),
      }),
    );
    return parseChainsOnIsolate(
      response.body,
      conversationless: true,
      tweetIndicator: 'tweet',
      pinnedTweets: const [],
      mapToThreads: true,
      includeReplies: false,
      showPinnedTweet: false,
      getTweetsCounter: getTweetsCounter,
      incrementTweetsCounter: incrementTweetsCounter,
    );
  }

  /// The posts the active account bookmarked (x.com/i/bookmarks), served by
  /// X's Bookmarks endpoint — like Likes, X only answers it for the account
  /// the request runs as. The timeline nests under data.bookmark_timeline_v2,
  /// so the GraphQL timeline parser reads it. The queryId is community-tracked
  /// (fa0311/twitter-openapi); refresh it when a 404 shows up.
  static Future<TweetStatus> getBookmarks({
    int count = 20,
    String? cursor,
    required int Function() getTweetsCounter,
    required void Function() incrementTweetsCounter,
  }) async {
    var variables = {
      "count": count,
      "includePromotedContent": true,
      if (cursor != null) "cursor": cursor,
    };

    var response = await _twitterApi.client.get(
      Uri.https('x.com', '/i/api/graphql/XD0ViOeSOW4YoeNTGjVaYw/Bookmarks', {
        'variables': jsonEncode(variables),
        'features': jsonEncode(_timelineFeatures),
      }),
    );

    return parseOffThread<TweetStatus>(response.body, ParseJob.bookmarks);
  }

  static Future<TweetStatus> getTweets(
    String id,
    String type,
    List<String> pinnedTweets, {
    int count = 10,
    String? cursor,
    bool includeReplies = true,
    bool includeRetweets = true,
    required int Function() getTweetsCounter,
    required void Function() incrementTweetsCounter,
  }) async {
    bool showPinnedTweet = true;

    Map<String, Object> defaultUserTweetsParam = {
      "variables": jsonEncode({
        "userId": "8341362",
        "count": 20,
        "includePromotedContent": true,
        "withQuickPromoteEligibilityTweetFields": true,
        "withVoice": true,
      }),
      "features": jsonEncode(_timelineFeatures),
      "fieldToggles": jsonEncode({"withArticlePlainText": false}),
    };

    Map<String, dynamic> variables = json.decode(defaultUserTweetsParam["variables"].toString());
    variables["userId"] = id;
    if (cursor != null) {
      variables['cursor'] = cursor;
    }
    variables['count'] = count;
    defaultUserTweetsParam["variables"] = json.encode(variables);

    late String path;
    if (type == "media") {
      path = "/i/api/graphql/9EovraBTXJYGSEQXZqlLmQ/UserMedia";
    } else {
      path = includeReplies
          ? "/i/api/graphql/D5eKzDa5ZoJuC1TCeAXbWA/UserTweetsAndReplies"
          : '/i/api/graphql/36rb3Xj3iJ64Q-9wKDjCcQ/UserTweets';
    }

    var response = await _twitterApi.client.get(Uri.https('x.com', path, defaultUserTweetsParam));

    //if this page is not first one on the profile page, dont add pinned tweet
    if (variables['cursor'] != null) showPinnedTweet = false;
    return parseChainsOnIsolate(
      response.body,
      conversationless: true,
      tweetIndicator: 'tweet',
      pinnedTweets: pinnedTweets,
      mapToThreads: includeReplies == false,
      includeReplies: includeReplies,
      showPinnedTweet: showPinnedTweet,
      getTweetsCounter: getTweetsCounter,
      incrementTweetsCounter: incrementTweetsCounter,
    );
  }

  static Future<Map<String, dynamic>> getBroadcastDetails(String key) async {
    var response = await _twitterApi.client.get(Uri.https('twitter.com', '/i/api/1.1/live_video_stream/status/$key'));

    return json.decode(response.body);
  }
}



