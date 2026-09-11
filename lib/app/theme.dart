import 'package:material_ui/material_ui.dart';

/// The single source of truth for the fork's Material 3 look: one theme built
/// from the active [ColorScheme] (dynamic accent or a seeded color), with every
/// component tuned consistently — cards, bars, sheets, fields.
ThemeData buildAppTheme({
  required ColorScheme colorScheme,
  required bool trueBlack,
  required bool disableAnimations,
}) {
  final black = trueBlack && colorScheme.brightness == Brightness.dark;
  final base = ThemeData(colorScheme: colorScheme, useMaterial3: true);

  final surface = black ? Colors.black : colorScheme.surface;
  final elevatedSurface = black ? const Color(0xFF121212) : colorScheme.surfaceContainerLow;

  return base.copyWith(
    scaffoldBackgroundColor: black ? Colors.black : colorScheme.surface,
    pageTransitionsTheme: disableAnimations
        ? const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: NoAnimationPageTransitionsBuilder(),
              TargetPlatform.iOS: NoAnimationPageTransitionsBuilder(),
            },
          )
        : null,
    appBarTheme: AppBarThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: black ? Colors.black : colorScheme.surfaceContainer,
      indicatorColor: colorScheme.secondaryContainer,
      elevation: 0,
      height: 68,
    ),
    cardTheme: CardThemeData(
      color: elevatedSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    ),
    dividerTheme: DividerThemeData(
      color: colorScheme.outlineVariant.withValues(alpha: 0.4),
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide.none,
      backgroundColor: colorScheme.surfaceContainerHigh,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      linearTrackColor: colorScheme.surfaceContainerHighest,
      linearMinHeight: 6,
      circularTrackColor: colorScheme.surfaceContainerHighest,
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      showDragHandle: true,
      backgroundColor: elevatedSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: Colors.transparent,
      labelStyle: base.textTheme.titleSmall,
      unselectedLabelStyle: base.textTheme.titleSmall,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.surfaceContainerHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(28),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: colorScheme.primaryContainer,
      foregroundColor: colorScheme.onPrimaryContainer,
      elevation: 0,
    ),
  );
}

class NoAnimationPageTransitionsBuilder extends PageTransitionsBuilder {
  const NoAnimationPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
      PageRoute<T> route, BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    return child;
  }
}
