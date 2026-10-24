import 'package:flutter_test/flutter_test.dart';
import 'package:quax/tweet/video_context.dart';

void main() {
  // _muted is a process-wide static, so each test starts from the same place.
  setUp(VideoContextState.resetForTests);

  group('VideoContextState', () {
    test('Should take the preference as the initial value only', () {
      // The first instance in the process sets the default; after that mute is
      // user-controlled, so a later scope must not reset it to the pref.
      VideoContextState(false);
      expect(VideoContextState(true).isMuted, isFalse,
          reason: 'A new scope is created per screen, and re-reading the preference on each one '
              'would undo a mute the reader just set');
    });

    test('Should share the state across every scope', () {
      final first = VideoContextState(false);
      final second = VideoContextState(false);

      // A contradiction is what flips it: muted is false, so a zero volume.
      first.setIsMuted(0.0);

      expect(first.isMuted, isTrue, reason: 'Muting applies to the scope that did it');
      expect(second.isMuted, isTrue,
          reason: 'Mute is app-wide: a video on another screen must come up muted too');
    });

    test('Should flip on a volume change that contradicts the current state', () {
      final state = VideoContextState(false);

      state.setIsMuted(0.0);
      expect(state.isMuted, isTrue,
          reason: 'Unmuted plus a zero volume is contradictory, so the volume wins');

      state.setIsMuted(1.0);
      expect(state.isMuted, isFalse,
          reason: 'Muted plus a non-zero volume is contradictory the other way');
    });

    test('Should ignore a volume change that agrees with the current state', () {
      final state = VideoContextState(false);

      state.setIsMuted(1.0);

      expect(state.isMuted, isFalse,
          reason: 'A non-zero volume while already unmuted is the same state, not a toggle. '
              'Flipping on it would make every video unmute itself when the player re-reports its '
              'volume');
    });
  });
}
