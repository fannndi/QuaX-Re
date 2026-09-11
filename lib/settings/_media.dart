import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/library/library_model.dart';

import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:pref/pref.dart';

class SettingsMediaFragment extends StatefulWidget {
  const SettingsMediaFragment({super.key});

  @override
  State<SettingsMediaFragment> createState() => _SettingsMediaFragmentState();
}

class _SettingsMediaFragmentState extends State<SettingsMediaFragment> {
  @override
  Widget build(BuildContext context) {
    var prefs = PrefService.of(context);

    List<DropdownMenuItem<String>> qualityItems() => [
          DropdownMenuItem(value: 'thumb', child: Text(L10n.of(context).quality_low)),
          DropdownMenuItem(value: 'small', child: Text(L10n.of(context).quality_medium)),
          DropdownMenuItem(value: 'medium', child: Text(L10n.of(context).quality_high)),
          DropdownMenuItem(value: 'large', child: Text(L10n.of(context).quality_maximum)),
        ];

    return Scaffold(
      appBar: AppBar(title: Text(L10n.current.media)),
      body: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: ListView(children: [
          PrefSwitch(
            pref: optionMediaDisableAutoload,
            title: Text(L10n.of(context).load_media_manually),
            subtitle: Text(L10n.of(context).load_media_manually_description),
          ),
          PrefDropdown(
              fullWidth: false,
              title: Text(L10n.of(context).image_quality),
              subtitle: Text(L10n.of(context).save_bandwidth_using_smaller_images),
              pref: optionImageQuality,
              items: qualityItems()),
          PrefDropdown(
              fullWidth: false,
              title: Text(L10n.of(context).video_quality),
              subtitle: Text(L10n.of(context).video_quality_description),
              pref: optionMediaVideoQuality,
              items: qualityItems()),
          PrefDropdown(
              fullWidth: false,
              title: Text(L10n.of(context).media_grid_columns),
              subtitle: Text(L10n.of(context).media_grid_columns_description),
              pref: optionMediaGridColumns,
              items: [
                for (var count in [1, 2, 3, 4, 5])
                  DropdownMenuItem(
                    value: count,
                    child: Text('$count'),
                  ),
              ]),
          PrefSwitch(
            pref: optionMediaDefaultMute,
            title: Text(L10n.of(context).mute_videos),
            subtitle: Text(L10n.of(context).mute_video_description),
          ),
          PrefSwitch(
            pref: optionMediaDefaultLoop,
            title: Text(L10n.of(context).loop_videos),
            subtitle: Text(L10n.of(context).loop_videos_description),
          ),
          PrefSwitch(
            pref: optionMediaDefaultAutoPlay,
            title: Text(L10n.of(context).autoplay_videos),
            subtitle: Text(L10n.of(context).autoplay_videos_description),
          ),
          PrefDropdown(
              fullWidth: false,
              title: Text(L10n.of(context).video_prefetch),
              subtitle: Text(L10n.of(context).video_prefetch_description),
              pref: optionMediaVideoPrefetchSeconds,
              items: [
                DropdownMenuItem(
                  value: 0,
                  child: Text(L10n.of(context).video_prefetch_unlimited),
                ),
                for (var seconds in [1, 5, 15, 30, 60])
                  DropdownMenuItem(
                    value: seconds,
                    child: Text(L10n.of(context).video_prefetch_seconds(seconds)),
                  ),
              ]),
          PrefSwitch(
            pref: optionMediaBackgroundPlayback,
            title: Text(L10n.of(context).allow_background_play),
            subtitle: Text(L10n.of(context).allow_background_play_description),
          ),
          PrefSwitch(
            pref: optionMediaAllowBackgroundPlayOtherApps,
            title: Text(L10n.of(context).allow_background_play_other_apps),
            subtitle: Text(L10n.of(context).allow_background_play_other_apps_description),
          ),
          // The fork keeps a single download destination: the hidden library.
          // Non-library handling (ask every time, or a fixed folder) is gone.
          PrefButton(
            onTap: () async {
              String? directoryPath = await FilePicker.getDirectoryPath();

              if (directoryPath == null) {
                return;
              }

              final ok = await LibraryModel(prefs).setupLibraryAt(directoryPath);
              if (ok && context.mounted) {
                setState(() {});
              }
            },
            title: Text(L10n.current.library),
            subtitle: Text(prefs.get<String>(optionLibraryPath) ?? L10n.current.not_set),
            child: Text(L10n.current.choose),
          ),
        ]),
      ),
    );
  }
}
