import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:quax/constants.dart';
import 'package:quax/tweet/_video.dart';
import 'package:quax/tweet/video_controller_pool.dart';
import 'package:quax/tweet/video_wakelock.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

class _Controller extends BetterPlayerController {
  bool playing;
  int pauses = 0;

  _Controller({this.playing = false})
    : super(
        const BetterPlayerConfiguration(
          autoDispose: false,
          handleLifecycle: false,
        ),
      );

  @override
  bool? isPlaying() => playing;

  @override
  bool? isVideoInitialized() => true;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> pause() async {
    pauses++;
    playing = false;
  }

  @override
  Future<void> play() async {
    playing = true;
  }
}

class _Wakelock extends WakelockPlusPlatformInterface {
  bool isEnabled = false;

  @override
  Future<void> toggle({required bool enable}) async => isEnabled = enable;

  @override
  Future<bool> get enabled async => isEnabled;
}

PooledVideo _pooled(_Controller controller, {bool pausable = true}) =>
    PooledVideo(
      controller: controller,
      downloadUrl: null,
      qualities: const [],
      pausableByPolicy: pausable,
    );

TweetVideo video(String tweetId) => TweetVideo(
  username: 'author',
  loop: false,
  alwaysPlay: true,
  tweetId: tweetId,
  metadata: TweetVideoMetadata(
    1,
    null,
    () => throw StateError('pool entry should be reused'),
  ),
);

Widget harness(
  VideoControllerPool pool,
  VideoContextState context,
  Widget child, {
  PrefServiceCache? prefs,
}) => MaterialApp(
  home: PrefService(
    service:
        prefs ??
        PrefServiceCache(
          cache: {
            optionMediaDefaultAutoPlay: true,
            optionMediaVideoQuality: 'high',
            optionMediaDefaultLoop: false,
            optionMediaBackgroundPlayback: true,
          },
        ),
    child: MultiProvider(
      providers: [
        Provider<VideoControllerPool>.value(value: pool),
        ChangeNotifierProvider<VideoContextState>.value(value: context),
      ],
      child: Scaffold(body: child),
    ),
  ),
);

void main() {
  late _Wakelock wakelock;
  late WakelockPlusPlatformInterface originalWakelock;

  setUp(() {
    VideoContextState.resetForTests();
    originalWakelock = wakelockPlusPlatformInstance;
    wakelock = _Wakelock();
    wakelockPlusPlatformInstance = wakelock;
  });

  tearDown(() {
    wakelockPlusPlatformInstance = originalWakelock;
    VideoWakelock.resetForTests();
  });

  testWidgets(
    'Should reconcile an already-playing controller when a tile attaches',
    (tester) async {
      final pool = VideoControllerPool();
      final context = VideoContextState(true);
      final active = _pooled(_Controller(playing: true));
      final other = _pooled(_Controller(playing: true));
      await pool.acquire('active:0:high:false', () async => active);
      await pool.acquire('other:0:high:false', () async => other);

      await tester.pumpWidget(harness(pool, context, video('active')));
      await tester.pumpAndSettle();

      expect(
        other.controller.isPlaying(),
        isFalse,
        reason:
            'A reused controller emits no new play event, so attach must still pause the '
            'other audible player',
      );
      expect(
        active.controller.isPlaying(),
        isTrue,
        reason: 'Reattaching the active player must preserve its playback position and state',
      );
      expect(
        wakelock.isEnabled,
        isTrue,
        reason:
            'The already-playing video still needs the wakelock even though no play event '
            'was emitted after this tile attached',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 600));
      pool.discard('active:0:high:false');
      pool.discard('other:0:high:false');
      context.dispose();
    },
  );

  testWidgets(
    'Should not attach a late controller after the tweet identity changes',
    (tester) async {
      final pool = VideoControllerPool();
      final context = VideoContextState(true);
      final oldController = _Controller();
      final newController = _Controller();
      final oldBuild = Completer<PooledVideo>();
      final oldVideo = _pooled(oldController);
      final newVideo = _pooled(newController);
      pool.acquire('old:0:high:false', () => oldBuild.future);
      await pool.acquire('new:0:high:false', () async => newVideo);
      final tweetId = ValueNotifier<String>('old');

      await tester.pumpWidget(
        harness(
          pool,
          context,
          ValueListenableBuilder<String>(
            valueListenable: tweetId,
            builder: (_, id, _) => video(id),
          ),
        ),
      );
      await tester.pump();

      tweetId.value = 'new';
      await tester.pumpAndSettle();
      oldBuild.complete(oldVideo);
      await tester.pumpAndSettle();

      final player = tester.widget<BetterPlayer>(find.byType(BetterPlayer));
      expect(
        identical(player.controller, newController),
        isTrue,
        reason:
            'The old acquisition completed after the widget was recycled; attaching it '
            'would show or control the wrong tweet even though the new controller was ready',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 600));
      pool.discard('old:0:high:false');
      pool.discard('new:0:high:false');
      tweetId.dispose();
      context.dispose();
    },
  );

  testWidgets('Should apply a live background-playback setting change', (
    tester,
  ) async {
    final pool = VideoControllerPool();
    final context = VideoContextState(true);
    final controller = _Controller(playing: true);
    final active = _pooled(controller);
    final prefs = PrefServiceCache(
      cache: {
        optionMediaDefaultAutoPlay: true,
        optionMediaVideoQuality: 'high',
        optionMediaDefaultLoop: false,
        optionMediaBackgroundPlayback: true,
      },
    );
    await pool.acquire('active:0:high:false', () async => active);

    await tester.pumpWidget(
      harness(pool, context, video('active'), prefs: prefs),
    );
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(
      controller.pauses,
      0,
      reason: 'Background playback starts enabled, so hiding the app must not pause the clip',
    );

    await prefs.set<bool>(optionMediaBackgroundPlayback, false);
    await tester.pump();

    expect(
      controller.pauses,
      1,
      reason:
          'TweetVideo must listen for the preference change and apply it immediately, '
          'rather than keeping the value captured at creation until the next lifecycle event',
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(
      controller.playing,
      isTrue,
      reason: 'Returning to the foreground resumes the clip that the new setting paused',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 600));
    pool.discard('active:0:high:false');
    context.dispose();
  });
}
