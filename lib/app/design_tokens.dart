import 'package:material_ui/material_ui.dart';

/// One spacing scale for the whole app. The screen gutter is 16: every text
/// block, media edge, section header and footer action starts there, which is
/// what keeps the layout symmetrical at a glance.
abstract final class AppSpace {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  static const EdgeInsets screen = EdgeInsets.symmetric(horizontal: lg);
  static const EdgeInsets card = EdgeInsets.all(lg);
  static const EdgeInsets row = EdgeInsets.symmetric(
    horizontal: lg,
    vertical: md,
  );
  static const EdgeInsets sheet = EdgeInsets.fromLTRB(xl, sm, xl, xl);
}

/// A closed radius family: 4 for micro badges, 8 for media/chips, 12 for
/// buttons/inputs/rows, 16 for cards, 24 for sheets and dialogs.
abstract final class AppRadius {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;

  static const BorderRadius xsAll = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius sheetTop = BorderRadius.vertical(
    top: Radius.circular(xl),
  );
}

abstract final class AppSize {
  static const double touch = 48;
  static const double button = 44;
  static const double buttonLarge = 48;
  static const double appBar = 56;
  static const double tabBar = 48;
  static const double navBar = 64;
  static const double row = 64;
  static const double icon = 20;
  static const double iconLarge = 24;
  static const double avatar = 40;
  static const double avatarLarge = 48;
  static const double profileAvatar = 80;

  /// Media stops taking over the reading context on tall phones.
  static const double mediaMaxViewportFraction = 0.6;
  static const double mediaMaxHeight = 560;
}

abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 200);
  static const Duration sheet = Duration(milliseconds: 250);
  static const Curve curve = Curves.easeOutCubic;
}

/// The monochrome surface ladder. The hue can come from [seed] (Graphite is a
/// true neutral, Stone a slightly warm one), while the surfaces and text stay
/// fixed so every screen has the same calm contrast.
abstract final class AppPalette {
  static const Color graphiteSeed = Color(0xFF808080);

  static ColorScheme scheme(
    Brightness brightness, {
    required Color seed,
    required bool trueBlack,
  }) {
    final ramp = brightness == Brightness.dark
        ? _darkRamp(trueBlack)
        : _lightRamp;
    final generated = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.neutral,
    );
    final dark = brightness == Brightness.dark;
    final primary = dark ? const Color(0xFFE8E8EA) : const Color(0xFF1B1B1D);
    final onPrimary = dark ? const Color(0xFF101012) : const Color(0xFFF8F8F6);
    final primaryContainer = dark
        ? const Color(0xFF2A2A2F)
        : const Color(0xFFDCDCD8);
    final onPrimaryContainer = dark
        ? const Color(0xFFF2F2F3)
        : const Color(0xFF1B1B1D);
    final secondary = dark ? const Color(0xFFB9B9BF) : const Color(0xFF4A4A4F);
    final onSecondary = dark
        ? const Color(0xFF1A1A1C)
        : const Color(0xFFF8F8F6);
    final secondaryContainer = dark
        ? const Color(0xFF26262B)
        : const Color(0xFFE4E4DF);
    final onSecondaryContainer = dark
        ? const Color(0xFFE9E9EB)
        : const Color(0xFF1B1B1D);

    return generated.copyWith(
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: primaryContainer,
      onPrimaryContainer: onPrimaryContainer,
      secondary: secondary,
      onSecondary: onSecondary,
      secondaryContainer: secondaryContainer,
      onSecondaryContainer: onSecondaryContainer,
      tertiary: secondary,
      onTertiary: onSecondary,
      tertiaryContainer: secondaryContainer,
      onTertiaryContainer: onSecondaryContainer,
      inversePrimary: dark ? const Color(0xFF1B1B1D) : const Color(0xFFE8E8EA),
      surface: ramp.surface,
      onSurface: ramp.onSurface,
      onSurfaceVariant: ramp.onSurfaceVariant,
      surfaceContainerLowest: ramp.lowest,
      surfaceContainerLow: ramp.low,
      surfaceContainer: ramp.container,
      surfaceContainerHigh: ramp.high,
      surfaceContainerHighest: ramp.highest,
      surfaceDim: ramp.dim,
      surfaceBright: ramp.bright,
      outline: ramp.outline,
      outlineVariant: ramp.outlineVariant,
      inverseSurface: ramp.inverseSurface,
      onInverseSurface: ramp.onInverseSurface,
      error: ramp.error,
      onError: ramp.onError,
      errorContainer: ramp.errorContainer,
      onErrorContainer: ramp.onErrorContainer,
    );
  }

  static _SurfaceRamp _darkRamp(bool trueBlack) => trueBlack
      ? const _SurfaceRamp(
          surface: Color(0xFF000000),
          lowest: Color(0xFF000000),
          low: Color(0xFF0B0B0C),
          container: Color(0xFF0F0F11),
          high: Color(0xFF131315),
          highest: Color(0xFF1B1B1E),
          dim: Color(0xFF000000),
          bright: Color(0xFF1B1B1E),
          outline: Color(0xFF4A4A51),
          outlineVariant: Color(0xFF2C2C31),
          onSurface: Color(0xFFF1F1F2),
          onSurfaceVariant: Color(0xFFA9A9AF),
          inverseSurface: Color(0xFFF1F1F2),
          onInverseSurface: Color(0xFF171719),
          error: Color(0xFFC98A8A),
          onError: Color(0xFF2A0E0E),
          errorContainer: Color(0xFF3A1D1D),
          onErrorContainer: Color(0xFFF2DADA),
        )
      : const _SurfaceRamp(
          surface: Color(0xFF161619),
          lowest: Color(0xFF101012),
          low: Color(0xFF1A1A1D),
          container: Color(0xFF1E1E22),
          high: Color(0xFF232327),
          highest: Color(0xFF2A2A2F),
          dim: Color(0xFF0F0F11),
          bright: Color(0xFF323237),
          outline: Color(0xFF4A4A51),
          outlineVariant: Color(0xFF2E2E33),
          onSurface: Color(0xFFF1F1F2),
          onSurfaceVariant: Color(0xFFA9A9AF),
          inverseSurface: Color(0xFFF1F1F2),
          onInverseSurface: Color(0xFF171719),
          error: Color(0xFFC98A8A),
          onError: Color(0xFF2A0E0E),
          errorContainer: Color(0xFF3A1D1D),
          onErrorContainer: Color(0xFFF2DADA),
        );

  static const _SurfaceRamp _lightRamp = _SurfaceRamp(
    surface: Color(0xFFFAFAF8),
    lowest: Color(0xFFFFFFFF),
    low: Color(0xFFF1F1EE),
    container: Color(0xFFEBEBE7),
    high: Color(0xFFE4E4DF),
    highest: Color(0xFFDDDDD7),
    dim: Color(0xFFE4E4DF),
    bright: Color(0xFFFFFFFF),
    outline: Color(0xFF8A8A8F),
    outlineVariant: Color(0xFFD5D5D0),
    onSurface: Color(0xFF171719),
    onSurfaceVariant: Color(0xFF5D5D62),
    inverseSurface: Color(0xFF171719),
    onInverseSurface: Color(0xFFF1F1F2),
    error: Color(0xFFA85454),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFF2DADA),
    onErrorContainer: Color(0xFF3A1D1D),
  );
}

class _SurfaceRamp {
  final Color surface;
  final Color lowest;
  final Color low;
  final Color container;
  final Color high;
  final Color highest;
  final Color dim;
  final Color bright;
  final Color outline;
  final Color outlineVariant;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color inverseSurface;
  final Color onInverseSurface;
  final Color error;
  final Color onError;
  final Color errorContainer;
  final Color onErrorContainer;

  const _SurfaceRamp({
    required this.surface,
    required this.lowest,
    required this.low,
    required this.container,
    required this.high,
    required this.highest,
    required this.dim,
    required this.bright,
    required this.outline,
    required this.outlineVariant,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.inverseSurface,
    required this.onInverseSurface,
    required this.error,
    required this.onError,
    required this.errorContainer,
    required this.onErrorContainer,
  });
}
