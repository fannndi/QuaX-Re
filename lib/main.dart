import 'dart:async';
import 'dart:developer';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:quax/constants.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/likes_vault.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/downloads/connectivity_watcher.dart';
import 'package:quax/downloads/download_notifications.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/downloads/video_cache.dart';
import 'package:quax/app/fritter_app.dart';
import 'package:quax/app/startup.dart';
import 'package:quax/tweet/video_controller_pool.dart';
import 'package:quax/home/_feed.dart';
import 'package:quax/likes/liked_tweet_model.dart';
import 'package:quax/tweet/_video.dart';
import 'package:quax/utils/crash_log.dart';
import 'package:quax/utils/image_decode.dart';
import 'package:quax/utils/network_status.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';

void main() {
  // The logging package defaults to INFO and every record is forwarded to
  // logcat below, which any app holding READ_LOGS (present on many OEM builds)
  // or a connected adb can read. Request URLs carry the reader's userId and
  // search terms, and liked-tweet ids are personal data, so in release only
  // warnings and worse are recorded.
  Logger.root.level = kDebugMode ? Level.ALL : Level.WARNING;

  Logger.root.onRecord.listen((event) async {
    log(event.message, error: event.error, stackTrace: event.stackTrace);
  });

  // Errors that escape a widget build or an async callback used to reach
  // logcat only, which is gone once the process dies. They also land in the
  // on-device crash log the reader can open from Settings now.
  runZonedGuarded(_boot, (error, stackTrace) {
    log('Uncaught error', error: error, stackTrace: stackTrace);
    CrashLog.record(error, stackTrace, kind: 'zone');
  });
}

Future<void> _boot() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    CrashLog.record(details.exception, details.stack, kind: 'flutter');
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stackTrace) {
    log('Uncaught platform error', error: error, stackTrace: stackTrace);
    CrashLog.record(error, stackTrace, kind: 'platform');
    return true;
  };
  await CrashLog.init();

  // Everything below can fail — preferences, migrations, the first queries —
  // and a failure that escapes without a runApp() leaves no frame at all: a
  // blank surface with nothing to retry. The last screen is the catch's job.
  try {
    await _startApp();
  } catch (e, stackTrace) {
    log('Unable to start QuaX', error: e, stackTrace: stackTrace);
    CrashLog.record(e, stackTrace, kind: 'startup');
    runApp(_StartupFailedApp(error: e, stackTrace: stackTrace));
  }
}

/// What every preference is before the reader has touched it. Kept out of
/// [_startApp] so the startup path reads as a sequence of steps rather than
/// as a page of data wedged into the middle of one.
final Map<String, dynamic> _prefDefaults = {
  optionDisableAnimations: false,
  optionTextScaleFactor: 1.0,
  optionDisableScreenshots: false,
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
  optionOpenLinksInEmbeddedBrowser: false,
  alwaysShowFullTweetContents: false,
  optionThemeMode: 'system',
  optionThemeColor: 'accent',
  optionThemeTrueBlack: true,
  optionThemeTrueBlackTweetCards: true,
  optionShowNavigationLabels: false,
  optionTweetsHideSensitive: true,
  optionLikedFirstToastShown: false,
  optionUseAbsoluteTimestamp: false,
};

Future<void> _startApp() async {
  // Flutter's 100 MiB default leaves nothing for the video decoders that share
  // this heap; see applyImageCacheLimits.
  applyImageCacheLimits(PaintingBinding.instance.imageCache);

  Intl.defaultLocale = 'en';

  final prefService = await PrefServiceShared.init(
    prefix: 'pref_',
    defaults: _prefDefaults,
  );

  await migrateMediaQualityPrefs(prefService);
  await migrateLibraryStoragePrefs(prefService);

  await _loadModels(prefService);

  final likedTweets = LikedTweetModel();
  unawaited(likedTweets.loadLikedIds());

  runApp(
    PrefService(
      service: prefService,
      child: MultiProvider(
        providers: [
          Provider(create: (context) => VideoControllerPool(maxSize: 2)),
          Provider<LikedTweetModel>.value(value: likedTweets),
          ChangeNotifierProvider(
            create: (_) =>
                VideoContextState(prefService.get(optionMediaDefaultMute)),
          ),
        ],
        child: FritterApp(),
      ),
    ),
  );
}

/// Loads what the screens assume is already there before the first frame: the
/// schema plus the background work that does not have to finish before anything
/// is drawn.
Future<void> _loadModels(BasePrefService prefService) async {
  // Run the migrations early, so models work. We also do this later on so we
  // can display errors to the user.
  try {
    await Repository().migrate();
  } catch (_) {
    // Ignore, as we'll catch it later instead
  }

  // Foreground-service notifications wired up for the download queue, the
  // persisted queue/history loaded, and the connectivity watcher primed so a
  // network coming back auto-resumes the retryable failures.
  unawaited(DownloadNotifications.ensure());
  unawaited(
    DownloadsModel().load().then(
      (_) => ConnectivityWatcher().ensure(prefService),
    ),
  );
  unawaited(NetworkStatus().check());
  // Primes the auto-cache index and applies the persisted cap before playback
  // can serve a clip that a previous, larger limit left behind.
  await VideoCache().load();
  await VideoCache().enforceLimit(prefService);
  // A killed likes import can leave its plaintext export in the cache.
  unawaited(LikesVault.cleanupStaleImports());
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
      title: 'QuaX-Re',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF080808),
      ),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'QuaX could not start',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
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
