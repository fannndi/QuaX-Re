import 'dart:async';
import 'dart:developer';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:quax/constants.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/downloads/connectivity_watcher.dart';
import 'package:quax/downloads/download_notifications.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/downloads/video_cache.dart';
import 'package:quax/app/fritter_app.dart';
import 'package:quax/app/startup.dart';
import 'package:quax/tweet/video_controller_pool.dart';
import 'package:quax/group/group_model.dart';
import 'package:quax/home/_feed.dart';
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

Future<void> main() async {
  Logger.root.onRecord.listen((event) async {
    log(event.message, error: event.error, stackTrace: event.stackTrace);
  });

  // Everything below can fail — preferences, migrations, the first queries —
  // and a failure that escapes without a runApp() leaves no frame at all: a
  // blank surface with nothing to retry. The last screen is the catch's job.
  try {
    await _startApp();
  } catch (e, stackTrace) {
    log('Unable to start QuaX', error: e, stackTrace: stackTrace);
    runApp(_StartupFailedApp(error: e, stackTrace: stackTrace));
  }
}

/// What every preference is before the reader has touched it. Kept out of
/// [_startApp] so the startup path reads as a sequence of steps rather than
/// as a page of data wedged into the middle of one.
final Map<String, dynamic> _prefDefaults = {
    optionConfirmClose: true,
    optionDisableAnimations: false,
    optionTextScaleFactor: 1.0,
    optionDisableScreenshots: false,
    optionLocale: optionLocaleDefault,
    optionLibraryVisibleInGallery: false,
    optionAutoCacheVideos: false,
    optionAutoCacheWifiOnly: true,
    optionVideoCacheLimitMb: 1024,
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
    alwaysShowFullTweetContents: false,
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
  
};

Future<void> _startApp() async {
  WidgetsFlutterBinding.ensureInitialized();

  setTimeagoLocales();

  final prefService = await PrefServiceShared.init(prefix: 'pref_', defaults: _prefDefaults);

  await migrateMediaQualityPrefs(prefService);

  final groupsModel = GroupsModel();
  final subscriptionsModel = SubscriptionsModel(groupsModel);
  await _loadModels(prefService, groupsModel, subscriptionsModel);

  runApp(PrefService(
      service: prefService,
      child: MultiProvider(
        providers: [
          Provider(create: (context) => groupsModel),
          Provider(create: (context) => VideoControllerPool(maxSize: 2)),
          Provider(create: (context) => subscriptionsModel),
          Provider(create: (context) => SavedTweetModel()),
          Provider(create: (context) => SavedTweetFolderModel()),
          Provider(create: (context) => LikedTweetModel()),
          Provider(create: (context) => SearchUsersModel()),
          ChangeNotifierProvider(create: (_) => VideoContextState(prefService.get(optionMediaDefaultMute))),
        ],
        child: FritterApp(),
      )));
}

/// Loads what the screens assume is already there before the first frame: the
/// schema, the followed accounts and their groups, plus the background work
/// that does not have to finish before anything is drawn.
Future<void> _loadModels(
    BasePrefService prefService, GroupsModel groupsModel, SubscriptionsModel subscriptionsModel) async {
  // Run the migrations early, so models work. We also do this later on so we
  // can display errors to the user.
  try {
    await Repository().migrate();
  } catch (_) {
    // Ignore, as we'll catch it later instead
  }

  await groupsModel.reloadGroups();
  await subscriptionsModel.reloadSubscriptions();

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
  // Which login the app talks to: the app bar shows it and the feeds key
  // their per-account state (scroll positions) on it. A failure here must
  // not stop the app from starting, the button just falls back to its icon.
  try {
    await loadActiveAccount();
  } catch (_) {
    // Keep the default (no active account known yet).
  }
}

/// Shown when startup itself threw. Deliberately built from nothing but
/// Flutter's own widgets: the database, the preferences and the localization
/// delegate are all suspects in a startup failure, and a screen that leans on
/// any of them would fail the same way and hand back the blank surface this
/// exists to prevent. The strings are hardcoded for the same reason — see
/// AGENTS.md's "never hardcode UI text", which this emergency path excepts.
class _StartupFailedApp extends StatelessWidget {
  const _StartupFailedApp({required this.error, required this.stackTrace});

  final Object error;
  final StackTrace stackTrace;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QuaX',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, colorSchemeSeed: const Color(0xFF080808)),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('QuaX could not start',
                    textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                Text('$error',
                    textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: () => main(),
                  child: const Text('Try again'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => _copyDetails(),
                  child: const Text('Copy details'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _copyDetails() {
    Clipboard.setData(ClipboardData(text: '$error\n\n$stackTrace'));
  }
}
