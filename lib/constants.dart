import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// The one native bridge the fork owns. Every Dart call has to use this name;
/// a typo in one local copy only surfaced as a runtime MissingPluginException.
const quaxMethodChannel = MethodChannel('browser_resolver');

const optionDisableAnimations = 'accessibility.disable_animations';
const optionTextScaleFactor = 'accessibility.text_scale_factor';

const optionDisableScreenshots = 'disable_screenshots';

const optionHomeDefaultFeedTab = 'home.default_feed_tab';

const optionImageQuality = 'media.size';
const optionMediaVideoQuality = 'media.video_quality';
const optionMediaDisableAutoload = 'media.disable_autoload';
const optionMediaQualitySplitMigrated = 'media.quality_split_migrated';
const optionMediaGridColumns = 'media.grid_columns';
const optionMediaDefaultMute = 'media.mute';
const optionMediaDefaultLoop = 'media.loop';
const optionMediaDefaultAutoPlay = 'media.auto_play';
const optionMediaBackgroundPlayback = 'media.allow_background_play';
const optionMediaAllowBackgroundPlayOtherApps =
    'media.allow_background_play.other_apps';
const optionMediaVideoPrefetchSeconds = 'media.video_prefetch_seconds';

// Hentoid-style hidden library: a picked folder (visible in file managers)
// holding downloaded media with a .nomedia marker so gallery apps ignore it.
const optionLibraryPath = 'library.path';
const optionLibraryVisibleInGallery = 'library.visibleInGallery';

// `hidden` stores the media inside the app-specific directory on the chosen
// volume (invisible to other apps on Android 11+), `visible` keeps the old
// user-picked folder.
const optionLibraryStorageMode = 'library.storageMode';
const libraryStorageHidden = 'hidden';
const libraryStorageVisible = 'visible';

// The shared-storage folder that holds QuaXAccount. It is stored separately
// from the library path because a hidden library lives under Android/data,
// which is deleted on uninstall, while the encrypted account backup exists to
// survive exactly that.
const optionVaultRoot = 'account.vaultRoot';

const optionLibrarySort = 'library.sort';
const optionLibraryFilter = 'library.filter';

// True when an account was added, re-signed in or removed after the last
// QuaXAccount vault write. The backup screen reads it once; nothing writes it
// on the hot path.
const optionAccountVaultDirty = 'account.vault_dirty';

// `count:max(liked_at)` at the last local-likes backup. The backup screen
// compares it with the live table instead of writing a preference on every tap
// on the heart.
const optionLikesVaultSnapshot = 'account.likes_vault_snapshot';
const optionAutoCacheVideos = 'cache.videos';
const optionAutoCacheWifiOnly = 'cache.wifiOnly';
const optionVideoCacheLimitMb = 'cache.limitMb';

const optionOpenLinksInEmbeddedBrowser = 'open_links_in_embedded_browser';

const alwaysShowFullTweetContents = 'always_show_full_tweet_contents';

const optionThemeMode = 'theme.mode';
const optionThemeColor = 'theme.color';
const optionThemeTrueBlack = 'theme.true_black';
const optionThemeTrueBlackTweetCards = 'theme.true_black_tweet_cards';
const optionShowNavigationLabels = 'theme.show_navigation_labels';
const optionUseAbsoluteTimestamp = "option.absolute_timestamp";

const themeColors = {
  'red': Colors.red,
  'orange': Colors.orange,
  'yellow': Colors.yellow,
  'green': Colors.green,
  'blue': Colors.blue,
  'indigo': Colors.indigo,
};

const optionTweetsHideSensitive = 'tweets.hide_sensitive';

const optionLikedFirstToastShown = 'saved.liked_first_toast_shown';

const optionNonConfirmationBiasMode = 'other.improve_non_confirmation_bias';

final Map<String, String> userAgentHeader = {
  'user-agent': "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Mobile Safari/537.3",
  "Pragma": "no-cache",
  "Cache-Control": "no-cache",
  // "If-Modified-Since": "Sat, 1 Jan 2000 00:00:00 GMT",
};

const String bearerToken =
    "Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA";

// Account selection strategy: cooldowns and flagging thresholds.
const Duration rateLimitFallback = Duration(minutes: 15);
const Duration notFoundCooldown = Duration(hours: 6);
const int notFoundThreshold = 3;

const shareLinkBase = 'https://x.com';

const routeHome = '/';
const routeProfile = '/profile';
const routeSearch = '/search';
const routeSettings = '/settings';
const routeStatus = '/status';

/// One read-only GraphQL contract from the 2026-11-20 community capture.
/// Query ids and methods live here so the client and live probe cannot drift.
class GraphQlEndpoint {
  const GraphQlEndpoint({
    required this.operation,
    required this.method,
    required this.queryId,
    required this.expectedRoot,
  });

  final String operation;
  final String method;
  final String queryId;
  final List<String> expectedRoot;

  String get path => '/i/api/graphql/$queryId/$operation';

  Uri uri({Map<String, dynamic>? variables, Map<String, String>? query}) =>
      Uri.https('x.com', path, {
        if (variables != null) 'variables': jsonEncode(variables),
        ...?query,
      });
}

const graphQlEndpoints = <String, GraphQlEndpoint>{
  'HomeTimeline': GraphQlEndpoint(
    operation: 'HomeTimeline',
    method: 'GET',
    queryId: 'KmJCeZ__ef1fNos7tKN_fg',
    expectedRoot: ['data', 'home', 'home_timeline_urt'],
  ),
  'HomeLatestTimeline': GraphQlEndpoint(
    operation: 'HomeLatestTimeline',
    method: 'POST',
    queryId: 'IVA5BUbeYPTrpYekQH7jiA',
    expectedRoot: ['data', 'home', 'home_timeline_urt'],
  ),
  'UserByRestId': GraphQlEndpoint(
    operation: 'UserByRestId',
    method: 'GET',
    queryId: 'mxaYWwt52eAb6OAzYHMVzg',
    expectedRoot: ['data', 'user', 'result'],
  ),
  'UserByScreenName': GraphQlEndpoint(
    operation: 'UserByScreenName',
    method: 'GET',
    queryId: 'AMIBMjtxEEATh4z8V9GtRg',
    expectedRoot: ['data', 'user', 'result'],
  ),
  'Following': GraphQlEndpoint(
    operation: 'Following',
    method: 'GET',
    queryId: 'eDqlbOS46zda8jDT8dEQ_Q',
    expectedRoot: ['data', 'user', 'result', 'timeline', 'timeline'],
  ),
  'Followers': GraphQlEndpoint(
    operation: 'Followers',
    method: 'GET',
    queryId: 'Xe3y9_ndZ9-RtWz8zd_wpg',
    expectedRoot: ['data', 'user', 'result', 'timeline', 'timeline'],
  ),
  'TweetDetail': GraphQlEndpoint(
    operation: 'TweetDetail',
    method: 'GET',
    queryId: 'dQDdKtt882nl-Km98FJGSQ',
    expectedRoot: ['data', 'threaded_conversation_with_injections_v2'],
  ),
  'SearchTimeline': GraphQlEndpoint(
    operation: 'SearchTimeline',
    method: 'GET',
    queryId: 'vLHjqbDv7TPFMBkIIO1nOA',
    expectedRoot: ['data', 'search_by_raw_query', 'search_timeline'],
  ),
  'Likes': GraphQlEndpoint(
    operation: 'Likes',
    method: 'GET',
    queryId: 'ZjyvI1V9gajq5eclHCObzA',
    expectedRoot: ['data', 'user', 'result'],
  ),
  'Bookmarks': GraphQlEndpoint(
    operation: 'Bookmarks',
    method: 'GET',
    queryId: 'fjf5b5Lu82lYMSBRhppK2g',
    expectedRoot: ['data', 'bookmark_timeline_v2'],
  ),
  'UserVideoTimeline': GraphQlEndpoint(
    operation: 'UserVideoTimeline',
    method: 'GET',
    queryId: '1UmMb8X-BFHS98GG6DyRsQ',
    expectedRoot: ['data', 'user', 'result'],
  ),
  'UserMedia': GraphQlEndpoint(
    operation: 'UserMedia',
    method: 'GET',
    queryId: 'QWOimofaocjeRda7Tm5pNA',
    expectedRoot: ['data', 'user', 'result'],
  ),
  'UserRepliesTimeline': GraphQlEndpoint(
    operation: 'UserRepliesTimeline',
    method: 'GET',
    queryId: 'fpl-c0_APDI3nZ1CeeBMbg',
    expectedRoot: ['data', 'user', 'result'],
  ),
  'UserOriginalsTimeline': GraphQlEndpoint(
    operation: 'UserOriginalsTimeline',
    method: 'GET',
    queryId: 'ZFKu1DFS63hgrkLzR3Hsdw',
    expectedRoot: ['data', 'user', 'result'],
  ),
};
