import 'package:flutter/widgets.dart';

/// Applies the live background-playback preference to one video. Keeping the
/// pause/resume decision pure makes the setting change testable without a
/// native player.
class VideoBackgroundPlaybackPolicy {
  bool enabled;
  bool _resumeAfterBackground = false;
  bool _pausedByPolicy = false;

  VideoBackgroundPlaybackPolicy({required this.enabled});

  void setEnabled(
    bool value, {
    required AppLifecycleState lifecycleState,
    required bool Function() isPlaying,
    required VoidCallback pause,
    required VoidCallback play,
  }) {
    enabled = value;
    if (enabled) {
      if (_pausedByPolicy && lifecycleState != AppLifecycleState.resumed) {
        _pausedByPolicy = false;
        _resumeAfterBackground = false;
        play();
      }
      return;
    }
    _apply(lifecycleState, isPlaying: isPlaying, pause: pause, play: play);
  }

  void onLifecycleChanged(
    AppLifecycleState state, {
    required bool Function() isPlaying,
    required VoidCallback pause,
    required VoidCallback play,
  }) {
    if (enabled) {
      _pausedByPolicy = false;
      _resumeAfterBackground = false;
      return;
    }
    _apply(state, isPlaying: isPlaying, pause: pause, play: play);
  }

  void _apply(
    AppLifecycleState state, {
    required bool Function() isPlaying,
    required VoidCallback pause,
    required VoidCallback play,
  }) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _resumeAfterBackground = isPlaying();
      _pausedByPolicy = _resumeAfterBackground;
      if (_resumeAfterBackground) pause();
    } else if (state == AppLifecycleState.resumed &&
        (_resumeAfterBackground || _pausedByPolicy)) {
      _resumeAfterBackground = false;
      _pausedByPolicy = false;
      play();
    }
  }
}
