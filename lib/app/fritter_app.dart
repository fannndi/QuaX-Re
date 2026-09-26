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
import 'package:quax/group/group_screen.dart';
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    var prefService = PrefService.of(context);

    // Set any already-enabled preferences
    setState(() {
      _themeMode = prefService.get(optionThemeMode);
      _themeColor = prefService.get(optionThemeColor);
      _trueBlack = prefService.get(optionThemeTrueBlack);
      _disableAnimations = prefService.get(optionDisableAnimations);
      _checkUpdates = prefService.get(optionShouldCheckForUpdates);
      _isSecure = prefService.get(optionDisableScreenshots);
      _textScaleFactor = prefService.get(optionTextScaleFactor);
    });

    prefService.addKeyListener(optionShouldCheckForUpdates, () {
      setState(() {});
    });

    // Whenever the "true black" preference is toggled, apply the toggle
    prefService.addKeyListener(optionThemeTrueBlack, () {
      setState(() {
        _trueBlack = prefService.get(optionThemeTrueBlack);
      });
    });

    prefService.addKeyListener(optionThemeMode, () {
      setState(() {
        _themeMode = prefService.get(optionThemeMode);
      });
    });

    prefService.addKeyListener(optionThemeColor, () {
      setState(() {
        _themeColor = prefService.get(optionThemeColor);
      });
    });

    prefService.addKeyListener(optionDisableScreenshots, () {
      setState(() {
        _isSecure = prefService.get(optionDisableScreenshots);
      });
    });

    prefService.addKeyListener(optionTextScaleFactor, () {
      setState(() {
        _textScaleFactor = prefService.get<double?>(optionTextScaleFactor) ?? 1.0;
      });
    });
  }

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
                    routeGroup: (context) => const GroupScreen(),
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


