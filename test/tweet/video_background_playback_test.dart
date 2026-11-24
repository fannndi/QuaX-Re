import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quax/tweet/video_background_playback.dart';

void main() {
  test('Should pause immediately when background playback is turned off while hidden', () {
    final policy = VideoBackgroundPlaybackPolicy(enabled: true);
    var playing = true;
    var pauses = 0;
    var plays = 0;
    void pause() {
      playing = false;
      pauses++;
    }

    void play() {
      playing = true;
      plays++;
    }

    policy.setEnabled(
      false,
      lifecycleState: AppLifecycleState.hidden,
      isPlaying: () => playing,
      pause: pause,
      play: play,
    );

    expect(
      playing,
      isFalse,
      reason:
          'The setting is live; turning it off must not wait for the next app pause '
          'before stopping audio in the background',
    );
    expect(pauses, 1);

    policy.onLifecycleChanged(
      AppLifecycleState.resumed,
      isPlaying: () => playing,
      pause: pause,
      play: play,
    );

    expect(
      plays,
      1,
      reason: 'A video paused by the new policy should resume when the reader returns',
    );
  });

  test('Should leave playback alone while background playback is enabled', () {
    final policy = VideoBackgroundPlaybackPolicy(enabled: true);
    var pauses = 0;
    var plays = 0;

    policy.onLifecycleChanged(
      AppLifecycleState.paused,
      isPlaying: () => true,
      pause: () => pauses++,
      play: () => plays++,
    );
    policy.onLifecycleChanged(
      AppLifecycleState.resumed,
      isPlaying: () => true,
      pause: () => pauses++,
      play: () => plays++,
    );

    expect(
      pauses,
      0,
      reason:
          'Background playback is allowed, so the app must not pause the clip',
    );
    expect(
      plays,
      0,
      reason: 'The clip never stopped, so returning to the foreground needs no resume',
    );
  });
}
