import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

/// Blurs the app the instant it loses focus, so the snapshot Android shows in
/// the recent-apps switcher (and any other background snapshot) carries a
/// frosted, unreadable frame instead of the actual timeline or gallery.
///
/// The switch is deliberately instant: a fade-out would race the snapshot.
class PrivacyShield extends StatefulWidget {
  final Widget child;

  const PrivacyShield({super.key, required this.child});

  @override
  State<PrivacyShield> createState() => _PrivacyShieldState();
}

class _PrivacyShieldState extends State<PrivacyShield> with WidgetsBindingObserver {
  bool _obscured = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _obscured = WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
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
  }

  @override
  Widget build(BuildContext context) {
    if (!_obscured) return widget.child;

    final colors = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
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
