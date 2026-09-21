import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'package:quax/constants.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/downloads/connectivity_watcher.dart';
import 'package:quax/downloads/download_notifications.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/downloads/video_cache.dart';
import 'package:quax/app/fritter_app.dart';
import 'package:quax/app/startup.dart';
import 'package:quax/group/feed_session_cache.dart';
import 'package:quax/tweet/video_controller_pool.dart';
import 'package:quax/group/group_model.dart';
import 'package:quax/home/_feed.dart';
import 'package:quax/import_data_model.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/saved/liked_tweet_model.dart';
import 'package:quax/saved/saved_tweet_folder_model.dart';
import 'package:quax/saved/saved_tweet_model.dart';
import 'package:quax/search/search_model.dart';
import 'package:quax/subscriptions/users_model.dart';
import 'package:quax/tweet/_video.dart';
import 'package:quax/utils/network_status.dart';
import 'package:quax/utils/tweet_freshness_index.dart';
import 'package:logging/logging.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';


Future<void> main() async {
  Logger.root.onRecord.listen((event) async {
    log(event.message, error: event.error, stackTrace: event.stackTrace);
  });

  if (Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  WidgetsFlutterBinding.ensureInitialized();

  setTimeagoLocales();

  final prefService = await PrefServiceShared.init(prefix: 'pref_', defaults: {
    optionConfirmClose: true,
    optionDisableAnimations: false,
    optionTextScaleFactor: 1.0,
    optionDisableScreenshots: false,
    optionLocale: optionLocaleDefault,
    optionLibraryVisibleInGallery: false,
    optionAutoCacheVideos: false,
    optionAutoCacheWifiOnly: true,
    optionVideoCacheLimitMb: 1024,
    optionHomeInitialTab: 'feed',
    optionHomeDefaultFeedTab: feedTabs[0].id.name,
    optionImageQuality: 'medium',
    optionMediaVideoQuality: 'medium',
    optionMediaDisableAutoload: false,
    optionMediaQualitySplitMigrated: false,
    optionMediaGridColumns: 3,
    optionMediaDefaultMute: true,
    optionMediaDefaultLoop: false,
    optionMediaDefaultAutoPlay: false,
    optionMediaBackgroundPlayback: true,
    optionMediaAllowBackgroundPlayOtherApps: false,
    optionMediaVideoPrefetchSeconds: 0,
    optionNonConfirmationBiasMode: false,
    optionShouldCheckForUpdates: false,
    optionOpenLinksInEmbeddedBrowser: false,
    optionSubscriptionGroupsOrderByAscending: true,
    optionDisableWarningsForUnrelatedPostsInFeed: false,
    alwaysShowFullTweetContents: false,
    optionSubscriptionGroupsOrderByField: 'name',
    optionSubscriptionOrderByAscending: true,
    optionSubscriptionOrderByField: 'name',
    optionSubscriptionOrderCustom: '',
    optionThemeMode: 'system',
    optionThemeColor: 'accent',
    optionThemeTrueBlack: true,
    optionThemeTrueBlackTweetCards: true,
    optionShowNavigationLabels: false,
    optionTweetsHideSensitive: true,
    optionSavedShowAllTab: true,
    optionSavedShowUnfiledTab: true,
    optionSavedShowFavoritesTab: true,
    optionSavedTabOrder: '',
    optionSavedFolderHintShown: false,
    optionLikedFirstToastShown: false,
    optionUseAbsoluteTimestamp: false,
    optionDefaultProfileTab: profileTabs[0].id.name,
  });

  await migrateMediaQualityPrefs(prefService);

  try {
    // Run the migrations early, so models work. We also do this later on so we can display errors to the user
    try {
      await Repository().migrate();
    } catch (_) {
      // Ignore, as we'll catch it later instead
    }

    var importDataModel = ImportDataModel();

    var groupsModel = GroupsModel(prefService);
    await groupsModel.reloadGroups();

    var subscriptionsModel = SubscriptionsModel(prefService, groupsModel);
    await subscriptionsModel.reloadSubscriptions();

    var feedSessionCache = FeedSessionCache();
    // Registration order matters: invalidateAll must run before any
    // GroupFeedShell reload listener, so by the time the shell remounts the
    // body via KeyedSubtree, the inner feed reads fresh controllers from the
    // cache. LinkedHashMap iterates in insertion order, and registering here
    // (before any shell exists) guarantees we win.
    groupsModel.addReloadListener('FeedSessionCache', feedSessionCache.invalidateAll);
    subscriptionsModel.addReloadListener('FeedSessionCache', feedSessionCache.invalidateAll);

    // Foreground-service notifications wired up for the download queue, the
    // persisted queue/history loaded, and the connectivity watcher primed so a
    // network coming back auto-resumes the retryable failures.
    unawaited(DownloadNotifications.ensure());
    unawaited(DownloadsModel().load().then((_) => ConnectivityWatcher().ensure(prefService)));
    unawaited(NetworkStatus().check());
    // Primes the auto-cache index so cache hits register right away.
    unawaited(VideoCache().load());
    // Snapshot of previously seen tweets, for the New/Old labels.
    unawaited(TweetFreshnessIndex().load());

    runApp(PrefService(        service: prefService,
        child: MultiProvider(
          providers: [
            Provider(create: (context) => groupsModel),
            Provider(create: (context) => feedSessionCache),
            Provider(create: (context) => VideoControllerPool(maxSize: 2)),
            ChangeNotifierProvider(create: (context) => importDataModel),
            Provider(create: (context) => subscriptionsModel),
            Provider(create: (context) => SavedTweetModel()),
            Provider(create: (context) => SavedTweetFolderModel()),
            Provider(create: (context) => LikedTweetModel()),
            Provider(create: (context) => SearchUsersModel()),
            ChangeNotifierProvider(create: (_) => VideoContextState(prefService.get(optionMediaDefaultMute))),
          ],
          child: FritterApp(),
        )));
  } catch (e, stackTrace) {
    log('Unable to start Fritter', error: e, stackTrace: stackTrace);
  }
}


