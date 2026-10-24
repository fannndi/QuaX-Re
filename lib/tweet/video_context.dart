import 'package:material_ui/material_ui.dart';

/// Mute is an app-wide toggle: muting one video keeps the next one muted, on
/// every screen.
///
/// A single static [ValueNotifier] is the source of truth. It used to forward
/// every change to `notifyListeners` on *every* per-scope instance, which made
/// one mute tap rebuild every video-controls subtree in the app at once — and
/// bought nothing, because nothing reads this through the Provider: every
/// consumer uses `context.read`. [ChangeNotifier] is kept only because
/// `ChangeNotifierProvider` requires one.
class VideoContextState extends ChangeNotifier {
  static final ValueNotifier<bool> _muted = ValueNotifier<bool>(false);
  static bool _initialised = false;

  VideoContextState(bool initialMuted) {
    // The pref is only the initial default; once set, mute is user-controlled.
    if (!_initialised) {
      _initialised = true;
      _muted.value = initialMuted;
    }
  }

  bool get isMuted => _muted.value;

  void setIsMuted(double volume) {
    final muted = _muted.value;
    if (muted && volume > 0 || !muted && volume == 0) {
      _muted.value = !muted;
    }
  }

  /// Test hook: back to the unmuted default with no preference applied, so one
  /// test's mute cannot decide the next one's starting state. `flutter test`
  /// runs every file in one process and [_muted] is static.
  @visibleForTesting
  static void resetForTests() {
    _initialised = false;
    _muted.value = false;
  }
}
