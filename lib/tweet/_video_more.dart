import 'package:better_player_plus/better_player_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:pref/pref.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/tweet/video_quality.dart';
import 'package:quax/tweet/_video_controls.dart';
import 'package:quax/utils/downloads.dart';
class VideoMoreButton extends StatefulWidget {
  final BetterPlayerController controller;
  final String username;
  final List<TweetVideoQuality> qualities;
  final String? downloadUrl;

  const VideoMoreButton({
    required this.controller,
    required this.username,
    required this.qualities,
    required this.downloadUrl,
  });

  @override
  State<VideoMoreButton> createState() => _VideoMoreButtonState();
}

class _VideoMoreButtonState extends State<VideoMoreButton> {
  bool _subtitlesEnabled = false;

  bool get _hasSubtitles => widget.controller.betterPlayerSubtitlesSourceList
      .any((s) => s.type != BetterPlayerSubtitlesSourceType.none);

  void _toggleSubtitles() {
    final list = widget.controller.betterPlayerSubtitlesSourceList;
    BetterPlayerSubtitlesSource? target;
    for (final source in list) {
      final isNone = source.type == BetterPlayerSubtitlesSourceType.none;
      if (_subtitlesEnabled ? isNone : !isNone) {
        target = source;
        break;
      }
    }
    if (target != null) widget.controller.setupSubtitleSource(target);
    setState(() => _subtitlesEnabled = !_subtitlesEnabled);
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      iconSize: 24.0,
      color: Colors.white,
      icon: const Icon(Icons.more_vert),
      onPressed: () => _openMenu(context),
    );
  }

  Future<void> _openMenu(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.speed),
              title: Text(L10n.of(sheetContext).playback_speed),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _openSpeedSheet(context, widget.controller);
              },
            ),
            if (widget.qualities.length > 1)
              ListTile(
                leading: const Icon(Icons.high_quality),
                title: Text(L10n.of(sheetContext).quality),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openQualitySheet(context, widget.controller, widget.qualities);
                },
              ),
            if (_hasSubtitles)
              ListTile(
                leading: Icon(_subtitlesEnabled ? Icons.closed_caption : Icons.closed_caption_off),
                title: Text(L10n.of(sheetContext).subtitles),
                trailing: _subtitlesEnabled ? const Icon(Icons.check) : null,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _toggleSubtitles();
                },
              ),
            ListTile(
              leading: const Icon(Icons.download),
              title: Text(L10n.of(sheetContext).download),
              onTap: () {
                Navigator.of(sheetContext).pop();
                downloadTweetVideo(context, widget.username, widget.downloadUrl);
              },
            ),
          ],
        ),
      ),
    );
  }
}

const _kSpeeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

Future<void> _openSpeedSheet(BuildContext context, BetterPlayerController controller) async {
  final current = videoValueOf(controller).speed;
  final chosen = await showModalBottomSheet<double>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (_) => _SpeedSheet(speeds: _kSpeeds, selected: current),
  );
  if (chosen != null) {
    await controller.setSpeed(chosen);
  }
}

Future<void> _openQualitySheet(
    BuildContext context, BetterPlayerController controller, List<TweetVideoQuality> qualities) async {
  final chosen = await showModalBottomSheet<TweetVideoQuality>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (_) => _QualitySheet(
      qualities: qualities,
      selectedUrl: controller.betterPlayerDataSource?.url,
    ),
  );
  if (chosen == null || chosen.url == controller.betterPlayerDataSource?.url) {
    return;
  }
  // setResolution preserves position and play/pause state but re-inits the data
  // source without re-applying volume, so a muted video would come back audible.
  final volume = videoValueOf(controller).volume;
  await controller.setResolution(chosen.url);
  await controller.setVolume(volume);
}

Future<void> downloadTweetVideo(BuildContext context, String username, String? downloadUrl) async {
  if (downloadUrl == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(L10n.current.download_media_no_url),
    ));
    return;
  }

  final videoUri = Uri.parse(downloadUrl);
  final fileName = '$username-${p.basename(videoUri.path)}';

  await downloadUriToPickedFile(context, videoUri, fileName, prefs: PrefService.of(context));
}

class _SpeedSheet extends StatelessWidget {
  final List<double> speeds;
  final double selected;

  const _SpeedSheet({required this.speeds, required this.selected});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: speeds.reversed.map((speed) {
          final isSelected = (speed - selected).abs() < 0.01;
          return ListTile(
            leading: isSelected ? const Icon(Icons.check) : const SizedBox(width: 24),
            title: Text('${speed}x'),
            onTap: () => Navigator.of(context).pop(speed),
          );
        }).toList(),
      ),
    );
  }
}

class _QualitySheet extends StatelessWidget {
  final List<TweetVideoQuality> qualities;
  final String? selectedUrl;

  const _QualitySheet({required this.qualities, required this.selectedUrl});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: qualities.map((quality) {
          final isSelected = quality.url == selectedUrl;
          return ListTile(
            leading: isSelected ? const Icon(Icons.check) : const SizedBox(width: 24),
            title: Text(quality.label),
            onTap: () => Navigator.of(context).pop(quality),
          );
        }).toList(),
      ),
    );
  }

}

