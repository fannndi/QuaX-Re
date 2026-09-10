import 'package:material_ui/material_ui.dart';
/// Mute is an app-wide toggle: muting one video keeps the next one muted, on
/// every screen. Tweet tiles each sit under their own [VideoContextState]
/// provider, so a single shared [ValueNotifier] is the source of truth and every
/// per-scope instance forwards its changes — that way all scopes stay in sync and
/// rebuild together (a plain static field only notified the one scope that fired).
class VideoContextState extends ChangeNotifier {
  static final ValueNotifier<bool> _muted = ValueNotifier(false);
  static bool _initialised = false;

  VideoContextState(bool initialMuted) {
    // The pref is only the initial default; once set, mute is user-controlled.
    if (!_initialised) {
      _initialised = true;
      _muted.value = initialMuted;
    }
    _muted.addListener(notifyListeners);
  }

  @override
  void dispose() {
    _muted.removeListener(notifyListeners);
    super.dispose();
  }

  bool get isMuted => _muted.value;

  void setIsMuted(double volume) {
    final muted = _muted.value;
    if (muted && volume > 0 || !muted && volume == 0) {
      _muted.value = !muted;
    }
  }
}

