import 'package:quax/app/privacy_shield.dart';
import 'package:quax/app/theme.dart';
import 'package:quax/app/update_checker.dart';
import 'package:quax/app/default_page.dart';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_portal/flutter_portal.dart';

import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/saved/saved_folders_screen.dart';
import 'package:quax/search/search.dart';
import 'package:quax/settings/settings.dart';
import 'package:quax/status.dart';
import 'package:quax/ui/errors.dart';
import 'package:logging/logging.dart';
import 'package:pref/pref.dart';
import 'package:secure_content/secure_content.dart';

class FritterApp extends StatefulWidget {
  const FritterApp({super.key});

  @override
  State<FritterApp> createState() => _FritterAppState();
}

class _FritterAppState extends State<FritterApp> {
  static final log = Logger('_MyAppState');

  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>(); // NEW: Navigator key

  String _themeMode = 'system';
  String _themeColor = 'accent';
  bool _disableAnimations = false;
  bool _trueBlack = true;
  bool _checkUpdates = false;
  bool _updateDialogShown = false;
  bool _isSecure = false;
  double _textScaleFactor = 1.0;

  BasePrefService? _prefs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // `listen: false`, with the key listeners attached exactly once below.
    // Reading the service as a dependency meant every preference write — and
    // scroll position is written twice a second while scrolling — re-ran this
    // method, which both rebuilt the whole app tree and pushed seven fresh
    // closures into a Set nothing ever removed them from. The root also
    // depends on MediaQuery through build, so a keyboard animation re-ran it
    // per frame and compounded both.
    final prefs = PrefService.of(context, listen: false);
    if (!identical(_prefs, prefs)) {
      _detachPreferenceListeners();
      _prefs = prefs;
      prefs.addKeyListener(optionShouldCheckForUpdates, _onCheckUpdatesChanged);
      prefs.addKeyListener(optionThemeTrueBlack, _onTrueBlackChanged);
      prefs.addKeyListener(optionThemeMode, _onThemeModeChanged);
      prefs.addKeyListener(optionThemeColor, _onThemeColorChanged);
      prefs.addKeyListener(optionDisableScreenshots, _onScreenshotsChanged);
      prefs.addKeyListener(optionDisableAnimations, _onDisableAnimationsChanged);
      prefs.addKeyListener(optionTextScaleFactor, _onTextChangedScale);
    }

    // No setState: didChangeDependencies is always followed by a build, and the
    // key listeners below cover the writes that happen after it.
    _readPreferences(prefs);
  }

  @override
  void dispose() {
    _detachPreferenceListeners();
    super.dispose();
  }

  void _detachPreferenceListeners() {
    final prefs = _prefs;
    if (prefs == null) return;
    _prefs = null;
    prefs.removeKeyListener(optionShouldCheckForUpdates, _onCheckUpdatesChanged);
    prefs.removeKeyListener(optionThemeTrueBlack, _onTrueBlackChanged);
    prefs.removeKeyListener(optionThemeMode, _onThemeModeChanged);
    prefs.removeKeyListener(optionThemeColor, _onThemeColorChanged);
    prefs.removeKeyListener(optionDisableScreenshots, _onScreenshotsChanged);
    prefs.removeKeyListener(optionDisableAnimations, _onDisableAnimationsChanged);
    prefs.removeKeyListener(optionTextScaleFactor, _onTextChangedScale);
  }

  void _readPreferences(BasePrefService prefs) {
    _themeMode = prefs.get(optionThemeMode);
    _themeColor = prefs.get(optionThemeColor);
    _trueBlack = prefs.get(optionThemeTrueBlack);
    _disableAnimations = prefs.get(optionDisableAnimations);
    _checkUpdates = prefs.get(optionShouldCheckForUpdates);
    _isSecure = prefs.get(optionDisableScreenshots);
    _textScaleFactor = prefs.get(optionTextScaleFactor);
  }

  void _onPreferenceChanged(void Function(BasePrefService prefs) read) {
    final prefs = _prefs;
    if (prefs == null || !mounted) return;
    setState(() => read(prefs));
  }

  void _onCheckUpdatesChanged() => _onPreferenceChanged((p) => _checkUpdates = p.get(optionShouldCheckForUpdates));

  void _onTrueBlackChanged() => _onPreferenceChanged((p) => _trueBlack = p.get(optionThemeTrueBlack));

  void _onThemeModeChanged() => _onPreferenceChanged((p) => _themeMode = p.get(optionThemeMode));

  void _onThemeColorChanged() => _onPreferenceChanged((p) => _themeColor = p.get(optionThemeColor));

  void _onScreenshotsChanged() => _onPreferenceChanged((p) => _isSecure = p.get(optionDisableScreenshots));

  void _onDisableAnimationsChanged() =>
      _onPreferenceChanged((p) => _disableAnimations = p.get(optionDisableAnimations));

  void _onTextChangedScale() =>
      _onPreferenceChanged((p) => _textScaleFactor = p.get<double?>(optionTextScaleFactor) ?? 1.0);

  @override
  Widget build(BuildContext context) {
    ThemeMode themeMode;
    switch (_themeMode) {
      case 'dark':
        themeMode = ThemeMode.dark;
        break;
      case 'light':
        themeMode = ThemeMode.light;
        break;
      case 'system':
        themeMode = ThemeMode.system;
        break;
      default:
        log.warning('Unknown theme mode preference: $_themeMode');
        themeMode = ThemeMode.system;
        break;
    }

    final systemOverlayStyle = SystemUiOverlayStyle.dark.copyWith(systemNavigationBarColor: Colors.transparent);
    SystemChrome.setSystemUIOverlayStyle(systemOverlayStyle);
    final systemScaleFactor = MediaQuery.textScalerOf(context).scale(1.0);

    return MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(_textScaleFactor * systemScaleFactor),
        ),
        child: DynamicColorBuilder(builder: (lightDynamic, darkDynamic) {
          return Portal(
              child: MaterialApp(
                  navigatorKey: _navigatorKey,
                  localizationsDelegates: const [
                    L10n.delegate,
                    ...GlobalMaterialLocalizations.delegates,
                  ],
                  supportedLocales: L10n.delegate.supportedLocales,
                  locale: const Locale('en'),
                  title: 'QuaX',
                  theme: buildAppTheme(
                    colorScheme: _themeColor == 'accent'
                        ? lightDynamic ??
                            ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.light)
                        : ColorScheme.fromSeed(
                            seedColor: themeColors[_themeColor]!
                                .harmonizeWith(lightDynamic?.primary ?? Colors.transparent),
                            brightness: Brightness.light),
                    trueBlack: _trueBlack,
                    disableAnimations: _disableAnimations,
                  ),
                  darkTheme: buildAppTheme(
                    colorScheme: (_themeColor == 'accent'
                            ? darkDynamic
                            : ColorScheme.fromSeed(
                                seedColor: themeColors[_themeColor]!
                                    .harmonizeWith(darkDynamic?.primary ?? Colors.transparent),
                                brightness: Brightness.dark)) ??
                        ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
                    trueBlack: _trueBlack,
                    disableAnimations: _disableAnimations,
                  ),
                  themeMode: themeMode,
                  initialRoute: '/',
                  routes: {
                    routeHome: (context) => const DefaultPage(),
                    routeProfile: (context) => const ProfileScreen(),
                    routeSearch: (context) => const ResultsScreen(),
                    routeSavedFolders: (context) => const SavedFoldersScreen(),
                    routeSettings: (context) => const SettingsScreen(),
                    routeStatus: (context) => const StatusScreen(),
                  },
                  builder: (context, child) {
                    if (_checkUpdates && !_updateDialogShown) {
                      _updateDialogShown = true;
                      // Use navigatorKey's context for showDialog
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        checkForUpdates(_navigatorKey.currentContext!);
                      });
                    }

                    // Replace the default red screen of death with a slightly friendlier one
                    ErrorWidget.builder = (FlutterErrorDetails details) => FullPageErrorWidget(
                          error: details.exception,
                          stackTrace: details.stack,
                          prefix: L10n.of(context).something_broke_in_fritter,
                        );

                    return PrivacyShield(
                      child: SecureContentScope(
                        enabled: _isSecure,
                        child: child ?? Container(),
                      ),
                    );
                  },
                ));
        }));
  }
}


