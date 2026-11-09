import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';

/// Blurs the app the instant it loses focus, so the snapshot Android shows in
/// the recent-apps switcher (and any other background snapshot) carries a
/// frosted, unreadable frame instead of the actual timeline or gallery.
///
/// The switch is deliberately instant: a fade-out would race the snapshot.
/// Android may still take the snapshot before the blurred frame lands, so the
/// window is additionally secured natively while the app is not resumed
/// (`MainActivity.onPause` does the same), and Dart lifts the flag again on
/// resume unless the "disable screenshots" preference wants it kept.
class PrivacyShield extends StatefulWidget {
  final Widget child;

  const PrivacyShield({super.key, required this.child});

  @override
  State<PrivacyShield> createState() => _PrivacyShieldState();
}

class _PrivacyShieldState extends State<PrivacyShield> with WidgetsBindingObserver {
  static const _channel = quaxMethodChannel;

  bool _obscured = false;
  bool _flagSynced = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _obscured = WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_flagSynced) return;
    _flagSynced = true;
    _applyRecentsSecurity(_obscured || _screenshotsDisabled());
  }

  bool _screenshotsDisabled() =>
      PrefService.of(context, listen: false).get<bool>(optionDisableScreenshots) ?? false;

  void _applyRecentsSecurity(bool secure) {
    _channel.invokeMethod('setRecentsSecure', {'secure': secure}).catchError((Object _) => null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final obscured = state != AppLifecycleState.resumed;
    if (obscured == _obscured) return;

    setState(() => _obscured = obscured);
    _applyRecentsSecurity(obscured || _screenshotsDisabled());
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // The tree shape must stay stable: returning the child bare when visible
    // and wrapped in a Stack when obscured remounted the whole Navigator on
    // every background, losing the open route, scroll position and dialogs.
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_obscured)
          Positioned.fill(
            child: IgnorePointer(
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                  child: ColoredBox(
                    color: colors.surface.withValues(alpha: 0.55),
                    child: Center(
                      child: Icon(Icons.lock_outline, size: 56, color: colors.primary),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
