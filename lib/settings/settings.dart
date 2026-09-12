import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localized_locales/flutter_localized_locales.dart';
import 'package:intl/intl.dart' show toBeginningOfSentenceCase;
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/library/library_model.dart';
import 'package:quax/ui/errors.dart';
import 'package:quax/utils/iterables.dart';
import 'package:quax/utils/timeline_cache.dart';
import 'package:quax/utils/tweet_cache_index.dart';

/// The whole Settings experience on one page — language & privacy, appearance,
/// downloads & media, cache, about. The account manager is deliberately not
/// here: switching accounts lives in the home app bar's account sheet.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  PackageInfo _packageInfo = PackageInfo(appName: '', packageName: '', version: '', buildNumber: '');

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _packageInfo = info);
    });
  }

  PrefDropdown<String> _languagePicker() {
    return PrefDropdown(
        fullWidth: false,
        title: Text(L10n.current.language),
        subtitle: Text(L10n.current.language_subtitle),
        pref: optionLocale,
        items: [
          DropdownMenuItem(value: optionLocaleDefault, child: Text(L10n.current.system)),
          ...L10n.delegate.supportedLocales
              .map((e) => SettingLocale.fromLocale(e))
              .sorted((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()))
              .map((e) => DropdownMenuItem(value: e.code, child: Text(e.name)))
        ]);
  }

  List<DropdownMenuItem<String>> _qualityItems() => [
        DropdownMenuItem(value: 'thumb', child: Text(L10n.current.quality_low)),
        DropdownMenuItem(value: 'small', child: Text(L10n.current.quality_medium)),
        DropdownMenuItem(value: 'medium', child: Text(L10n.current.quality_high)),
        DropdownMenuItem(value: 'large', child: Text(L10n.current.quality_maximum)),
      ];

  /// Wipes the offline caches (stored timelines, tweet-id index, gallery
  /// thumbnails and the image cache) so the next visit fetches everything
  /// fresh. Downloaded library files are never touched.
  Future<void> _clearCache(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(L10n.of(dialogContext).are_you_sure),
        content: Text(L10n.of(dialogContext).clear_cache_description),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(L10n.of(dialogContext).cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(L10n.of(dialogContext).delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await TimelineCache.clearAll();
    TweetCacheIndex().clear();
    try {
      final thumbs = Directory(p.join((await getTemporaryDirectory()).path, 'thumbs'));
      if (await thumbs.exists()) {
        await thumbs.delete(recursive: true);
      }
    } catch (_) {
      // Thumbnails regenerate on demand.
    }
    clearMemoryImageCache();
    try {
      await clearDiskCachedImages();
    } catch (_) {
      // Image cache failures are harmless.
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).cache_cleared)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = PrefService.of(context);
    final appVersion = 'v${_packageInfo.version}+${_packageInfo.buildNumber}';

    return Scaffold(
      appBar: AppBar(title: Text(L10n.of(context).settings)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + MediaQuery.of(context).padding.bottom),
        children: [
          _SettingsSection(
            title: L10n.of(context).general,
            tiles: [
              _languagePicker(),
              PrefSwitch(
                title: Text(L10n.of(context).disable_screenshots),
                subtitle: Text(L10n.of(context).disable_screenshots_hint),
                pref: optionDisableScreenshots,
              ),
            ],
          ),
          _SettingsSection(
            title: L10n.of(context).theme,
            tiles: [
              PrefDropdown(
                  fullWidth: false,
                  title: Text(L10n.of(context).theme_mode),
                  pref: optionThemeMode,
                  items: [
                    DropdownMenuItem(value: 'system', child: Text(L10n.of(context).system)),
                    DropdownMenuItem(value: 'light', child: Text(L10n.of(context).light)),
                    DropdownMenuItem(value: 'dark', child: Text(L10n.of(context).dark)),
                  ]),
              PrefDropdown(
                  fullWidth: false,
                  title: Text(L10n.of(context).theme),
                  pref: optionThemeColor,
                  items: [
                    const DropdownMenuItem(value: 'accent', child: Text('Accent')),
                    ...themeColors.entries.getRange(0, themeColors.values.length - 1).map((scheme) =>
                        DropdownMenuItem(value: scheme.key, child: Text(toBeginningOfSentenceCase(scheme.key)!)))
                  ]),
              PrefSwitch(
                title: Text(L10n.of(context).true_black),
                pref: optionThemeTrueBlack,
                subtitle: Text(L10n.of(context).use_true_black_for_the_dark_mode_theme),
              ),
            ],
          ),
          _SettingsSection(
            title: L10n.of(context).media,
            tiles: [
              _LibraryFolderTile(prefs: prefs),
              PrefDropdown(
                  fullWidth: false,
                  title: Text(L10n.of(context).video_quality),
                  subtitle: Text(L10n.of(context).video_quality_description),
                  pref: optionMediaVideoQuality,
                  items: _qualityItems()),
              PrefDropdown(
                  fullWidth: false,
                  title: Text(L10n.of(context).image_quality),
                  subtitle: Text(L10n.of(context).save_bandwidth_using_smaller_images),
                  pref: optionImageQuality,
                  items: _qualityItems()),
              PrefSwitch(
                pref: optionMediaDefaultMute,
                title: Text(L10n.of(context).mute_videos),
                subtitle: Text(L10n.of(context).mute_video_description),
              ),
              PrefSwitch(
                pref: optionMediaBackgroundPlayback,
                title: Text(L10n.of(context).allow_background_play),
                subtitle: Text(L10n.of(context).allow_background_play_description),
              ),
            ],
          ),
          _SettingsSection(
            title: L10n.of(context).data,
            tiles: [
              ListTile(
                leading: const Icon(Icons.cleaning_services_outlined),
                title: Text(L10n.of(context).clear_cache),
                subtitle: Text(L10n.of(context).clear_cache_description,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () => _clearCache(context),
              ),
            ],
          ),
          _SettingsSection(
            title: L10n.of(context).app_info,
            tiles: [
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(L10n.of(context).version),
                subtitle: Text(appVersion),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: appVersion));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(L10n.of(context).copied_version_to_clipboard)));
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.copyright_outlined),
                title: Text(L10n.of(context).licenses),
                onTap: () => showLicensePage(
                    context: context,
                    applicationName: L10n.of(context).fritter,
                    applicationVersion: appVersion,
                    applicationLegalese: L10n.of(context).released_under_the_mit_license,
                    applicationIcon: Container(
                      margin: const EdgeInsets.all(12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(48.0),
                        child: Image.asset(
                          'assets/icon.png',
                          height: 48.0,
                          width: 48.0,
                        ),
                      ),
                    )),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The library folder row: shows where downloads live and re-runs the folder
/// setup (hidden subfolder + `.nomedia`) when tapped.
class _LibraryFolderTile extends StatefulWidget {
  final BasePrefService prefs;

  const _LibraryFolderTile({required this.prefs});

  @override
  State<_LibraryFolderTile> createState() => _LibraryFolderTileState();
}

class _LibraryFolderTileState extends State<_LibraryFolderTile> {
  bool _busy = false;

  Future<void> _pick() async {
    final picked = await FilePicker.getDirectoryPath();
    if (picked == null || !mounted) return;

    setState(() => _busy = true);
    final error = ValueNotifier<String?>(null);
    final ok = await LibraryModel(widget.prefs).setupLibraryAt(picked, error: error);
    if (!mounted) return;
    setState(() => _busy = false);

    if (!ok && error.value != null) {
      showSnackBar(context, icon: '🙊', message: error.value!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.prefs.get<String>(optionLibraryPath);

    return ListTile(
      leading: const Icon(Icons.folder_outlined),
      title: Text(L10n.of(context).library),
      subtitle: Text(path == null || path.isEmpty ? L10n.of(context).not_set : path,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: _busy
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.chevron_right),
      onTap: _busy ? null : _pick,
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

class SettingLocale {
  final String code;
  final String name;

  SettingLocale(this.code, this.name);

  factory SettingLocale.fromLocale(Locale locale) {
    var code = locale.toLanguageTag().replaceAll('-', '_');
    var name = LocaleNamesLocalizationsDelegate.nativeLocaleNames[code] ?? code;

    return SettingLocale(code, name);
  }
}
