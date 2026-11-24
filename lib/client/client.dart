import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui' show Locale;

import 'package:quax/utils/twitter_dates.dart';
import 'package:dart_twitter_api/twitter_api.dart';
import 'package:flutter/foundation.dart';
import 'package:quax/catcher/exceptions.dart';
import 'package:quax/client/account_selector.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/client_regular_account.dart';
import 'package:quax/client/client_unauthenticated.dart';
import 'package:quax/client/headers.dart';
import 'package:quax/client/rate_limit_tracker.dart';
import 'package:quax/constants.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/profile/profile_model.dart';
import 'package:quax/user.dart';
import 'package:quax/utils/iterables.dart';
import 'package:quax/utils/timeline_cache.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

part 'client_parsing.dart';
part 'client_models.dart';

const Duration _defaultTimeout = Duration(seconds: 30);

/// Key for the in-flight request map. The account identity is part of the key:
/// an identical URI requested after an account switch must never join the
/// previous login's response. The revision catches a re-selection that changes
/// which account is preferred even if the session id is unchanged.
@visibleForTesting
String requestCoalescingKey(
  Uri uri, {
  String? body,
  bool accountScoped = false,
}) =>
    '${activeAccount.value?.id}\u0000${accountsRevision.value}\u0000'
    '${accountScoped ? 'SCOPED' : 'ANY'}\u0000'
    '${body == null ? 'GET' : 'POST'}\u0000$uri\u0000${body ?? ''}';

@visibleForTesting
Future<List<Account>> Function()? debugAccountsReader;

@visibleForTesting
Future<http.Response> Function(
  Uri uri, {
  Map<String, String>? headers,
  required Logger log,
})?
debugGuestFetchOverride;

class _QuackerTwitterClient extends TwitterClient {
  static final log = Logger('_QuackerTwitterClient');

  _QuackerTwitterClient()
    : super(consumerKey: '', consumerSecret: '', token: '', secret: '');

  // Identical requests flying at the same time (two tabs refreshing, a soft
  // refresh racing the pager) share one response instead of burning another
  // rate-limit slot.
  static final Map<String, Future<http.Response>> _inflight = {};

  @override
  Future<http.Response> get(
    Uri uri, {
    Map<String, String>? headers,
    Duration? timeout,
  }) => _coalesceGet(uri, headers: headers);

  /// A request that must run as the account the user chose, never as whichever
  /// other login the health selector would rotate to. Likes and Bookmarks are
  /// the two endpoints in this app that X answers per session identity.
  static Future<http.Response> getScoped(
    Uri uri, {
    Map<String, String>? headers,
  }) => _coalesceGet(uri, headers: headers, accountScoped: true);

  static Future<http.Response> _coalesceGet(
    Uri uri, {
    Map<String, String>? headers,
    bool accountScoped = false,
  }) {
    // `timeout` is deliberately unused: a coalesced caller used to get the
    // *first* caller's deadline, so a caller asking for 5s silently waited 30s.
    // Callers that need a shorter bound can wrap the returned future.
    final key = requestCoalescingKey(uri, accountScoped: accountScoped);
    final running = _inflight[key];
    if (running != null) return running;

    late final Future<http.Response> future;
    future = fetch(uri, headers: headers, accountScoped: accountScoped)
        .timeout(_defaultTimeout)
        .then<http.Response>((response) {
          if (response.statusCode >= 200 && response.statusCode < 300) {
            return response;
          } else {
            return Future.error(HttpException(response));
          }
        })
        .whenComplete(() {
          if (identical(_inflight[key], future)) _inflight.remove(key);
        });

    _inflight[key] = future;
    return future;
  }

  /// Authenticated JSON POST for GraphQL operations X serves as POST
  /// (HomeLatestTimeline). Mirrors [get]'s status handling and request
  /// coalescing. Static because `TwitterApi.client` is typed as the
  /// package's AbstractTwitterClient, which has no such helper.
  static Future<http.Response> postJson(
    Uri uri, {
    Map<String, String>? headers,
    required String body,
    bool accountScoped = false,
  }) {
    // Keyed on the method, body and account as well as the URI: a GET whose
    // string form happens to match must never share the response, and neither
    // must the same request after an account switch.
    final key = requestCoalescingKey(
      uri,
      body: body,
      accountScoped: accountScoped,
    );
    final running = _inflight[key];
    if (running != null) return running;

    late final Future<http.Response> future;
    future =
        fetch(uri, headers: headers, body: body, accountScoped: accountScoped)
            .timeout(_defaultTimeout)
            .then<http.Response>((response) {
              if (response.statusCode >= 200 && response.statusCode < 300) {
                return response;
              } else {
                return Future.error(HttpException(response));
              }
            })
            .whenComplete(() {
              if (identical(_inflight[key], future)) _inflight.remove(key);
            });

    _inflight[key] = future;
    return future;
  }

  /// Tries accounts (healthy ones first, then flagged ones as a fallback),
  /// retrying on another account when one returns a 429 (rate-limited for that
  /// endpoint, tracked in memory) or a 401/404 (session or queryId rejected).
  /// Rate limits are per-endpoint, so a 429 on one endpoint never blocks another.
  ///
  /// A real request is always attempted before any error: with accounts, each is
  /// tried; with none, an unauthenticated (guest) request is sent. Errors surface
  /// only from actual responses: [RateLimitedException] when every account was
  /// rate-limited on the endpoint, [NoWorkingAccountException] when they all
  /// returned 404/401, and [NoAccountAvailableException] only when there is no
  /// account and the guest request also failed. Network-level failures (socket,
  /// timeout, TLS) are absorbed once per fetch with a short pause, since they
  /// never reached X and are no account's fault; a second one is surfaced as-is.
  ///
  /// [accountScoped] turns off rotation: Likes and Bookmarks are answered per
  /// session identity, so falling back to another login would show one account's
  /// private data under another. If the active account is unusable the request
  /// fails instead.
  static Future<http.Response> fetch(
    Uri uri, {
    Map<String, String>? headers,
    String? body,
    bool accountScoped = false,
  }) async {
    // Capture before the first await: the coalescing key was made from this same
    // in-memory choice, and a switch may update SQLite while getAccounts() runs.
    final requestedScopedAccountId = accountScoped
        ? activeAccount.value?.id
        : null;
    final endpoint = uri.path;
    final now = DateTime.now();
    final accounts = await (debugAccountsReader?.call() ?? getAccounts());
    final selector = AccountSelector(
      accounts,
      now,
      isRateLimited: (a) => RateLimitTracker.isLimited(a.id, endpoint, now),
    );
    final active = accountScoped
        ? accounts.firstWhereOrNull(
            (a) => requestedScopedAccountId == null
                ? a.isActive
                : a.id == requestedScopedAccountId,
          )
        : null;
    if (accountScoped && active == null) {
      throw NoAccountAvailableException();
    }
    if (accountScoped &&
        RateLimitTracker.isLimited(active!.id, endpoint, now)) {
      throw RateLimitedException();
    }
    if (accountScoped && active!.isSessionExpired) {
      // A rejected session cannot be retried into working. Answer straight away
      // so the UI can offer a re-login instead of spending a request on a 401.
      throw NoWorkingAccountException();
    }
    final tried = <String>{};
    final terminalResponses = <int, http.Response>{};
    var transportAttempts = 0;
    var networkFailures = 0;
    var retriedTransactionId = false;
    Account? retryAccount;
    Object? lastNetworkError;
    StackTrace? lastNetworkStackTrace;

    while (true) {
      final account =
          retryAccount ??
          (accountScoped
              ? (tried.isEmpty ? active : null)
              : selector.pick(exclude: tried));
      retryAccount = null;
      if (account == null) break;
      tried.add(account.id);

      final authHeader = _decodeAuthHeader(account);
      if (authHeader == null) {
        // A corrupt row is not a network failure. Exclude it without spending
        // the retry budget or delaying the next healthy login.
        continue;
      }

      transportAttempts++;
      http.Response response;
      try {
        response = await XRegularAccount().fetch(
          uri,
          headers: headers,
          body: body,
          log: log,
          authHeader: authHeader,
        );
      } on Object catch (e, st) {
        lastNetworkError = e;
        lastNetworkStackTrace = st;
        if (++networkFailures >= 2) break;
        await Future<void>.delayed(const Duration(seconds: 1));
        tried.remove(
          account.id,
        ); // the network failed, not the account: it may be retried
        continue;
      }
      final code = response.statusCode;

      if (code < 200 || code >= 300 && kDebugMode) {
        debugPrint('QuaX fetch $code ${uri.path}');
      }

      // A 403 means the transaction-id key is wrong, not that this account is
      // unusable. Drop the cached generator and retry the same account once.
      if (code == 403 &&
          !retriedTransactionId &&
          TwitterHeaders.invalidateNow()) {
        retriedTransactionId = true;
        tried.remove(account.id);
        retryAccount = account;
        continue;
      }

      if (code >= 200 && code < 300) {
        if (response.headers['x-rate-limit-remaining'] == '0') {
          RateLimitTracker.flag(
            account.id,
            endpoint,
            _resetFromHeaders(response),
          );
        } else {
          RateLimitTracker.clear(account.id, endpoint);
        }
        if (!account.isClean) {
          _bestEffortHealthWrite(
            () => recordAccountSuccess(account.id, requestStartedAt: now),
          );
        }
        return response;
      }

      terminalResponses[code] = response;
      if (code == 429) {
        RateLimitTracker.flag(
          account.id,
          endpoint,
          _resetFromHeaders(response),
        );
        continue;
      }
      if (code == 401) {
        TwitterHeaders.invalidateIfStale();
        _bestEffortHealthWrite(() => recordAuthFailure(account.id));
        continue;
      }
      if (code == 404) {
        TwitterHeaders.invalidateIfStale();
        // A GraphQL 404 usually means a rotated query id, not broken auth.
        if (!uri.path.contains('/i/api/graphql/')) {
          _bestEffortHealthWrite(() => recordNotFound(account.id));
        }
        continue;
      }
      return response; // other errors surfaced immediately
    }

    if (!accountScoped && transportAttempts == 0) {
      // A POST body is private data; no usable account means no request.
      if (body != null) throw NoAccountAvailableException();
      // No account at all (or every row was malformed): still attempt a guest
      // read so we never error before sending one.
      final guest =
          await (debugGuestFetchOverride?.call(
                uri,
                headers: headers,
                log: log,
              ) ??
              fetchUnauthenticated(uri, headers: headers, log: log));
      if (guest.statusCode >= 200 && guest.statusCode < 300) return guest;
      throw NoAccountAvailableException(statusCode: guest.statusCode);
    }

    if (terminalResponses.isNotEmpty) {
      final statuses = terminalResponses.keys;
      if (statuses.every((status) => status == 429)) {
        throw RateLimitedException();
      }
      if (statuses.every((status) => status == 401 || status == 404)) {
        throw NoWorkingAccountException();
      }
      // Mixed terminal failures return a real response, selected by a fixed
      // priority rather than whichever account happened to answer last.
      for (final status in const [401, 404, 429, 403, 400, 500]) {
        final response = terminalResponses[status];
        if (response != null) return response;
      }
      return terminalResponses[statuses.reduce((a, b) => a < b ? a : b)]!;
    }

    if (lastNetworkError != null) {
      Error.throwWithStackTrace(lastNetworkError, lastNetworkStackTrace!);
    }
    // Scoped request with only malformed rows, or no selectable account.
    throw NoWorkingAccountException();
  }

  static Map<String, String>? _decodeAuthHeader(Account account) {
    try {
      final decoded = json.decode(account.authHeader as String);
      if (decoded is! Map) return null;
      final header = <String, String>{};
      for (final entry in decoded.entries) {
        if (entry.key is! String || entry.value is! String) return null;
        header[entry.key as String] = entry.value as String;
      }
      return header;
    } on Object {
      return null;
    }
  }

  static void _bestEffortHealthWrite(Future<void> Function() write) {
    unawaited(
      Future<void>.sync(write)
          .catchError((Object error, StackTrace stackTrace) {
            log.fine('Account health write failed', error, stackTrace);
          }),
    );
  }

  static DateTime _resetFromHeaders(http.Response response) {
    final reset = response.headers['x-rate-limit-reset']; // epoch seconds
    // tryParse: X has sent non-numeric and float-valued resets during incidents,
    // and this runs on the *success* path — an int.parse here would throw away a
    // perfectly good response and the whole page with it.
    final seconds = reset == null ? null : int.tryParse(reset);
    if (seconds != null) {
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    }
    return DateTime.now().add(rateLimitFallback);
  }
}

class Twitter {
  static final TwitterApi _twitterApi = TwitterApi(
    client: _QuackerTwitterClient(),
  );

  /// Test seam for the account-selection policy: exercises the real fetch loop
  /// (health, retries, 403 invalidation) without a socket. Production code
  /// always goes through the client wrapper.
  @visibleForTesting
  static Future<http.Response> debugFetch(
    Uri uri, {
    String? body,
    bool accountScoped = false,
  }) => _QuackerTwitterClient.fetch(
    uri,
    body: body,
    accountScoped: accountScoped,
  );

  /// The feature flags the live web client sends with every timeline call
  /// (captured from x.com in 2026-11). X shapes and strips responses by these;
  /// a stale or partial map is what makes a client look unusual.
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
    "post_ctas_fetch_enabled": true,
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
    "responsive_web_nested_quote_preview_enabled": true,
    "responsive_web_profile_redirect_enabled": true,
    "responsive_web_twitter_article_tweet_consumption_enabled": true,
    "rweb_cashtags_composer_attachment_enabled": true,
    "rweb_cashtags_enabled": true,
    "rweb_conversational_replies_downvote_enabled": false,
    "rweb_sports_post_context_enabled": true,
    "rweb_tipjar_consumption_enabled": false,
    "rweb_video_screen_enabled": false,
    "standardized_nudges_misinfo": true,
    "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled":
        true,
    "verified_phone_label_enabled": false,
    "view_counts_everywhere_api_enabled": true,
    "x_elections_post_context_enabled": true,
    "responsive_web_made_on_x_label_enabled": false,
  };

  /// Sent alongside the timeline features, exactly as the web client does.
  static const Map<String, Object> _timelineFieldToggles = {
    "withPayments": false,
  };

  /// The Likes endpoint sends this pair; the other timelines only send
  /// withPayments.
  static const Map<String, Object> _likesFieldToggles = {
    "withPayments": false,
    "withArticlePlainText": false,
  };

  static Future<http.Response> _requestGraphql(
    String operation, {
    required Map<String, dynamic> variables,
    Map<String, dynamic>? features,
    Map<String, dynamic>? fieldToggles,
    bool accountScoped = false,
  }) {
    final endpoint = graphQlEndpoints[operation]!;
    final payload = <String, dynamic>{
      'variables': variables,
      'features': ?features,
      'fieldToggles': ?fieldToggles,
    };
    if (endpoint.method == 'POST') {
      return _QuackerTwitterClient.postJson(
        endpoint.uri(),
        body: jsonEncode(payload),
        accountScoped: accountScoped,
      );
    }
    final uri = endpoint.uri(
      variables: variables,
      query: {
        ...?(features == null ? null : {'features': jsonEncode(features)}),
        ...?(fieldToggles == null
            ? null
            : {'fieldToggles': jsonEncode(fieldToggles)}),
      },
    );
    return accountScoped
        ? _QuackerTwitterClient.getScoped(uri)
        : _twitterApi.client.get(uri);
  }

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
    final endpoint = graphQlEndpoints['UserByRestId']!;
    final uri = endpoint.uri(
      variables: {
        'userId': id,
        'withHighlightedLabel': true,
        'withSafetyModeUserFields': true,
        'withSuperFollowsUserFields': true,
      },
      query: {'features': jsonEncode(_profileFeatures)},
    );

    return _getProfile(uri);
  }

  static Future<Profile> getProfileByScreenName(String screenName) async {
    if (screenName.startsWith('@')) {
      screenName = screenName.substring(1);
    }
    final endpoint = graphQlEndpoints['UserByScreenName']!;
    final uri = endpoint.uri(
      variables: {'screen_name': screenName, 'withGrokTranslatedBio': true},
      query: {
        'features': jsonEncode(_profileFeatures),
        'fieldToggles': jsonEncode({
          'withPayments': false,
          'withAuxiliaryUserLabels': true,
        }),
      },
    );

    return _getProfile(uri);
  }

  static Future<Profile> _getProfile(Uri uri) async {
    var response = await _twitterApi.client.get(uri);
    return parseOffThread<Profile>(
      response.body,
      ParseJob.profile,
      extra: uri.toString(),
    );
  }

  static Future<PaginatedUsers> friendsList(
    String userId,
    int count, {
    String? cursor,
  }) => _graphqlFollows(userId, count, cursor: cursor, operation: 'Following');

  // GraphQL "Followers"
  static Future<PaginatedUsers> followersList(
    String userId,
    int count, {
    String? cursor,
  }) => _graphqlFollows(userId, count, cursor: cursor, operation: 'Followers');

  // Shared cursor-paginated GraphQL user-list fetch (Following / Followers share
  // the same timeline shape; only the operation differs).
  static Future<PaginatedUsers> _graphqlFollows(
    String userId,
    int count, {
    String? cursor,
    required String operation,
  }) async {
    final response = await _requestGraphql(
      operation,
      variables: {
        "userId": userId,
        "count": count,
        "cursor": ?cursor,
        "includePromotedContent": false,
        "withGrokTranslatedBio": true,
      },
      features: _timelineFeatures,
    );

    return parseOffThread<PaginatedUsers>(response.body, ParseJob.follows);
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

    // `parseFollows` already builds UserWithExtra objects; the round-trip
    // through toJson()/fromJson() only dropped fields the pair disagreed on.
    return Follows(
      cursorBottom: response.nextCursorStr,
      cursorTop: response.previousCursorStr,
      users: response.users?.whereType<UserWithExtra>().toList() ?? [],
    );
  }

  static Future<TweetStatus> getTweet(String id, {String? cursor}) async {
    final variables = <String, dynamic>{
      "focalTweetId": "0",
      "with_rux_injections": false,
      "rankingMode": "Relevance",
      "includePromotedContent": true,
      "withCommunity": true,
      "withQuickPromoteEligibilityTweetFields": true,
      "withBirdwatchNotes": true,
      "withVoice": true,
    };
    variables["focalTweetId"] = id;
    if (cursor != null) variables['cursor'] = cursor;

    final cacheKey = TimelineCache.keyFor('thread.$id');
    try {
      final endpoint = graphQlEndpoints['TweetDetail']!;
      final uri = endpoint.uri(
        variables: variables,
        query: {
          'features': jsonEncode(_timelineFeatures),
          'fieldToggles': jsonEncode({
            "withArticleRichContentState": true,
            "withArticlePlainText": false,
            "withArticleSummaryText": false,
            "withArticleVoiceOver": false,
            "withGrokAnalyze": false,
            "withDisallowedReplyControls": false,
          }),
        },
      );
      final response = await _twitterApi.client.get(uri);
      final parsed = await parseOffThread<TweetStatus>(
        response.body,
        ParseJob.tweetDetail,
        extra: uri.toString(),
      );
      if (cursor == null) {
        // Cache only a body the parser accepted: a moved response shape must
        // not overwrite the last readable thread.
        unawaited(TimelineCache.write(cacheKey, response.body));
      }
      return parsed;
    } on TwitterError {
      // A GraphQL error or moved root is not an offline read. Surface it and
      // keep the last good cache entry untouched.
      rethrow;
    } on Exception {
      // Offline (or X unreachable): serve the stored conversation, if any.
      // Errors (TypeError/RangeError) mean the shape moved, and the cache is
      // not a valid substitute for a body the parser cannot read.
      if (cursor == null) {
        final cached = await TimelineCache.read(cacheKey);
        if (cached != null) {
          return await parseOffThread<TweetStatus>(
            cached,
            ParseJob.tweetDetail,
          );
        }
      }
      rethrow;
    }
  }

  /// The variables both search endpoints share; only `product` and a few flags
  /// differ, and the two copies of this map had already drifted apart.
  static Map<String, dynamic> _searchVariables(
    String query,
    int limit,
    String product, {
    String? cursor,
  }) {
    final variables = {
      "rawQuery": query,
      "count": limit,
      "querySource": "typed_query",
      "product": product,
    };
    if (cursor != null) variables['cursor'] = cursor;
    return variables;
  }

  static Future<TweetStatus> searchTweets(
    String query, {
    int limit = 20,
    String? cursor,
    String product = "Latest",
  }) async {
    var variables = _searchVariables(query, limit, product, cursor: cursor)
      ..["withGrokTranslatedBio"] = product == 'Top' || product == 'People'
      ..["withQuickPromoteEligibilityTweetFields"] = false;

    final response = await _requestGraphql(
      'SearchTimeline',
      variables: variables,
      features: _timelineFeatures,
    );
    return parseOffThread<TweetStatus>(
      response.body,
      ParseJob.search,
      extra: product,
    );
  }

  static Future<UserSearchPage> searchUsers(
    String query, {
    int limit = 25,
    String? cursor,
  }) async {
    var variables = _searchVariables(query, limit, 'People', cursor: cursor)
      ..["withDownvotePerspective"] = false
      ..["withReactionsMetadata"] = false
      ..["withReactionsPerspective"] = false
      ..["withGrokTranslatedBio"] = true
      ..["withQuickPromoteEligibilityTweetFields"] = false;

    final response = await _requestGraphql(
      'SearchTimeline',
      variables: variables,
      features: _timelineFeatures,
    );
    // On the worker isolate, like every other page: the hand-rolled copy of the
    // walk used to run here and blocked the frame for a page of hundreds of KB.
    return parseOffThread<UserSearchPage>(response.body, ParseJob.searchUsers);
  }

  /// The For You (ranked) home timeline. The variables mirror what x.com
  /// actually sends (see the recorded fixture): crucially `requestContext:
  /// "launch"` on the first page — without it X keeps serving a stale slice of
  /// the ranked feed. [seenTweetIds] carries what is already on screen so a
  /// refresh comes back with genuinely different posts instead of a repeat.
  /// [id], [type] and [includeReplies] are deprecated and ignored: the ranked
  /// home operation does not take a profile id or reply policy. They remain in
  /// the signature because existing UI callers still pass them.
  static Future<TweetStatus> getTimelineTweets(
    String id,
    String type, {
    List<String>? pinnedTweets,
    List<String>? seenTweetIds,
    int count = 10,
    String? cursor,
    bool includeReplies = true,
    required int Function() getTweetsCounter,
    required void Function() incrementTweetsCounter,
    void Function()? resetTweetsCounter,
  }) async {
    final variables = <String, dynamic>{
      "count": count,
      "includePromotedContent": true,
      "withCommunity": true,
      if (cursor == null) "requestContext": "launch" else "cursor": cursor,
      if (cursor == null && seenTweetIds != null && seenTweetIds.isNotEmpty)
        "seenTweetIds": seenTweetIds,
    };

    final response = await _requestGraphql(
      'HomeTimeline',
      variables: variables,
      features: _timelineFeatures,
      fieldToggles: _timelineFieldToggles,
      // For You is personalised; falling back to another login would show a
      // different reader's feed under the chosen account.
      accountScoped: true,
    );
    // Pinned posts only belong on the first page.
    return parseChainsOnIsolate(
      response.body,
      conversationless: false,
      tweetIndicator: 'tweet',
      pinnedTweets: pinnedTweets ?? [],
      showPinnedTweet: cursor == null,
      getTweetsCounter: getTweetsCounter,
      incrementTweetsCounter: incrementTweetsCounter,
      resetTweetsCounter: resetTweetsCounter,
      expectedRoot: graphQlEndpoints['HomeTimeline']!.expectedRoot,
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
    void Function()? resetTweetsCounter,
  }) async {
    final variables = <String, dynamic>{
      "count": count,
      "enableRanking": false,
      "includePromotedContent": true,
      if (cursor == null) "requestContext": "launch" else "cursor": cursor,
    };

    final response = await _requestGraphql(
      'HomeLatestTimeline',
      variables: variables,
      features: _timelineFeatures,
      fieldToggles: _timelineFieldToggles,
      // Scoped: the chronological list belongs to the chosen login, so the health
      // selector must not swap in another account's timeline.
      accountScoped: true,
    );
    return parseChainsOnIsolate(
      response.body,
      conversationless: false,
      tweetIndicator: 'tweet',
      pinnedTweets: const [],
      showPinnedTweet: false,
      getTweetsCounter: getTweetsCounter,
      incrementTweetsCounter: incrementTweetsCounter,
      resetTweetsCounter: resetTweetsCounter,
      expectedRoot: graphQlEndpoints['HomeLatestTimeline']!.expectedRoot,
    );
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
    void Function()? resetTweetsCounter,
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

    final response = await _requestGraphql(
      'Likes',
      variables: variables,
      features: _timelineFeatures,
      fieldToggles: _likesFieldToggles,
      accountScoped: true,
    );
    return parseChainsOnIsolate(
      response.body,
      conversationless: true,
      tweetIndicator: 'tweet',
      pinnedTweets: const [],
      showPinnedTweet: false,
      getTweetsCounter: getTweetsCounter,
      incrementTweetsCounter: incrementTweetsCounter,
      resetTweetsCounter: resetTweetsCounter,
      expectedRoot: graphQlEndpoints['Likes']!.expectedRoot,
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
    void Function()? resetTweetsCounter,
  }) async {
    var variables = {
      "count": count,
      "includePromotedContent": true,
      "cursor": ?cursor,
    };

    final response = await _requestGraphql(
      'Bookmarks',
      variables: variables,
      features: _timelineFeatures,
      accountScoped: true,
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
    required int Function() getTweetsCounter,
    required void Function() incrementTweetsCounter,
    void Function()? resetTweetsCounter,
  }) async {
    // The web's profile tabs are separate operations now (captured 2026-10):
    // originals, replies, videos and a photo grid. The old UserTweets /
    // UserTweetsAndReplies / UserMedia query ids answer 404.
    late final String operation;
    late final Map<String, dynamic> variables;
    if (type == 'media') {
      operation = 'UserVideoTimeline';
      variables = {
        "userId": id,
        "count": count,
        "includePromotedContent": false,
        "withClientEventToken": false,
        "withBirdwatchNotes": false,
        "withVoice": true,
      };
    } else if (type == 'photos') {
      operation = 'UserMedia';
      variables = {
        "userId": id,
        "count": count,
        "includePromotedContent": false,
        "withClientEventToken": false,
        "withBirdwatchNotes": false,
        "withVoice": true,
      };
    } else if (includeReplies) {
      operation = 'UserRepliesTimeline';
      variables = {
        "userId": id,
        "count": count,
        "includePromotedContent": true,
        "withCommunity": true,
        "withVoice": true,
      };
    } else {
      operation = 'UserOriginalsTimeline';
      variables = {
        "userId": id,
        "count": count,
        "includePromotedContent": true,
        "withQuickPromoteEligibilityTweetFields": true,
        "withVoice": true,
      };
    }
    if (cursor != null) {
      variables['cursor'] = cursor;
    }

    final response = await _requestGraphql(
      operation,
      variables: variables,
      features: _timelineFeatures,
      fieldToggles: _timelineFieldToggles,
    );

    // Pinned tweets only belong on the first page of the posts/replies tabs;
    // the video and photo grids have no pinned slot.
    final showPinnedTweet =
        cursor == null && type != 'media' && type != 'photos';
    return parseChainsOnIsolate(
      response.body,
      conversationless: true,
      tweetIndicator: 'tweet',
      pinnedTweets: pinnedTweets,
      showPinnedTweet: showPinnedTweet,
      getTweetsCounter: getTweetsCounter,
      incrementTweetsCounter: incrementTweetsCounter,
      resetTweetsCounter: resetTweetsCounter,
      expectedRoot: graphQlEndpoints[operation]!.expectedRoot,
    );
  }

  static Future<Map<String, dynamic>> getBroadcastDetails(String key) async {
    var response = await _twitterApi.client.get(
      Uri.https('twitter.com', '/i/api/1.1/live_video_stream/status/$key'),
    );

    return json.decode(response.body);
  }
}
