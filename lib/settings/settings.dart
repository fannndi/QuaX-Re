import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/settings/_about.dart';
import 'package:quax/settings/_general.dart';
import 'package:quax/settings/_media.dart';
import 'package:quax/settings/_theme.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The fork's settings: the few things worth a screen — language/general,
/// accounts, downloads & media, theme — plus the about box. Home-page
/// customisation, accessibility, post appearance and data export were dropped
/// to keep the app three tabs wide and simple.
class SettingsScreen extends StatefulWidget {
  final String? initialPage;

  const SettingsScreen({super.key, this.initialPage});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  PackageInfo _packageInfo = PackageInfo(appName: '', packageName: '', version: '', buildNumber: '');

  @override
  void initState() {
    super.initState();

    Future.microtask(() async {
      var packageInfo = await PackageInfo.fromPlatform();

      setState(() {
        _packageInfo = packageInfo;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    var appVersion = 'v${_packageInfo.version}+${_packageInfo.buildNumber}';

    return Scaffold(
      appBar: AppBar(title: Text(L10n.of(context).settings)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 16.0 + MediaQuery.of(context).padding.bottom),
        children: [
          ListTile(
            title: Text(L10n.of(context).general),
            leading: Icon(Icons.miscellaneous_services),
            subtitle: Text(
              L10n.of(context).language,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const SettingsGeneralFragment()),
            ),
          ),
          ListTile(
            title: Text(L10n.of(context).media),
            leading: Icon(Icons.perm_media),
            subtitle: Text(
              "${L10n.of(context).image_quality}, ${L10n.of(context).video_quality}, ${L10n.of(context).mute_videos}, ${L10n.of(context).library}",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const SettingsMediaFragment()),
            ),
          ),
          ListTile(
            title: Text(L10n.of(context).theme),
            subtitle: Text(
              "${L10n.of(context).theme_mode}, ${L10n.of(context).theme}, ${L10n.of(context).true_black}, ${L10n.of(context).true_black_tweet_cards} ${L10n.of(context).show_navigation_labels}",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
            leading: Icon(Icons.palette),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const SettingsThemeFragment()),
            ),
          ),
          const SizedBox(
            height: 8.0,
          ),
          Card(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: Column(children: [
                ListTile(
                  title: Text(
                    L10n.of(context).app_info,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                SettingsAboutFragment(
                  appVersion: appVersion,
                )
              ])),
        ],
      ),
    );
  }
}
