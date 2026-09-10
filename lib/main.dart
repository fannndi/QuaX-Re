import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'package:quax/constants.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/downloads/download_notifications.dart';
import 'package:quax/app/fritter_app.dart';
import 'package:quax/app/startup.dart';
import 'package:quax/group/feed_session_cache.dart';
import 'package:quax/tweet/video_controller_pool.dart';
import 'package:quax/group/group_model.dart';
import 'package:quax/home/_feed.dart';
import 'package:quax/home/home_model.dart';
import 'package:quax/import_data_model.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/saved/liked_tweet_model.dart';
import 'package:quax/saved/saved_tweet_folder_model.dart';
import 'package:quax/saved/saved_tweet_model.dart';
import 'package:quax/search/search_model.dart';
import 'package:quax/subscriptions/users_model.dart';
import 'package:quax/tweet/_video.dart';
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
    optionDownloadPath: '',
    optionDownloadType: optionDownloadTypeAsk,
    optionHomePages: ['feed', 'notifs', 'saved', 'downloads', 'settings'],
    optionLocale: optionLocaleDefault,
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
    optionUserTrendsLocations: jsonEncode({
      'active': {'name': 'Worldwide', 'woeid': 1},
      'locations': [
        {'name': 'Worldwide', 'woeid': 1}
      ]
    }),
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

    var homeModel = HomeModel(prefService, groupsModel);
    await homeModel.loadPages();

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

    // Notification bar wired up for the Hentoid-style download queue.
    unawaited(DownloadNotifications.ensure());

    runApp(PrefService(        service: prefService,
        child: MultiProvider(
          providers: [
            Provider(create: (context) => groupsModel),
            Provider(create: (context) => feedSessionCache),
            Provider(create: (context) => VideoControllerPool(maxSize: 2)),
            Provider(create: (context) => homeModel),
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


