import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/settings/_about.dart';
import 'package:quax/settings/_general.dart';
import 'package:quax/settings/_media.dart';
import 'package:quax/settings/_theme.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The fork's settings: the few things worth a screen — language/general,
/// downloads & media, theme — plus the about box. Account switching lives in
/// the home app bar's account sheet; home-page customisation, accessibility,
/// post appearance and data export were dropped to keep the app simple.
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
        padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + MediaQuery.of(context).padding.bottom),
        children: [
          _SettingsSection(
            title: L10n.of(context).general,
            tiles: [
              _SettingsEntry(
                icon: Icons.miscellaneous_services_outlined,
                title: L10n.of(context).general,
                subtitle: L10n.of(context).language,
                builder: (context) => const SettingsGeneralFragment(),
              ),
            ],
          ),
          _SettingsSection(
            title: L10n.of(context).media,
            tiles: [
              _SettingsEntry(
                icon: Icons.perm_media_outlined,
                title: L10n.of(context).media,
                subtitle:
                    "${L10n.of(context).image_quality}, ${L10n.of(context).video_quality}, ${L10n.of(context).mute_videos}, ${L10n.of(context).library}",
                builder: (context) => const SettingsMediaFragment(),
              ),
            ],
          ),
          _SettingsSection(
            title: L10n.of(context).theme,
            tiles: [
              _SettingsEntry(
                icon: Icons.palette_outlined,
                title: L10n.of(context).theme,
                subtitle:
                    "${L10n.of(context).theme_mode}, ${L10n.of(context).theme}, ${L10n.of(context).true_black}, ${L10n.of(context).true_black_tweet_cards} ${L10n.of(context).show_navigation_labels}",
                builder: (context) => const SettingsThemeFragment(),
              ),
            ],
          ),
          _SettingsSection(
            title: L10n.of(context).app_info,
            tiles: [
              Card(
                child: SettingsAboutFragment(
                  appVersion: appVersion,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> tiles;

  const _SettingsSection({required this.title, required this.tiles});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
          child: Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
          ),
        ),
        Card(
          child: Column(children: tiles),
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

class _SettingsEntry extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder builder;

  const _SettingsEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: builder)),
    );
  }
}
