
import 'package:dart_twitter_api/twitter_api.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/utils/downloads.dart';
import 'package:path/path.dart' as path;
import 'package:pref/pref.dart';

void showMediaActionsSheet(BuildContext context, Media item, String? username) {
  final isVideoLike = item.type == 'video' || item.type == 'animated_gif';
  final variantUrl = _largestVideoVariantUrl(item);
  final mediaUrl = Uri.parse(isVideoLike ? variantUrl! : '${item.mediaUrlHttps}:orig');
  final fileName = '$username-${path.basename(mediaUrl.path)}';

  showModalBottomSheet(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.download),
            title: Text(L10n.of(sheetContext).download),
            onTap: () {
              Navigator.pop(sheetContext);
              downloadUriToPickedFile(context, mediaUrl, fileName, prefs: PrefService.of(context));
            },
          ),
          ListTile(
            leading: const Icon(Icons.share),
            title: Text(L10n.of(sheetContext).share),
            onTap: () {
              Navigator.pop(sheetContext);
              downloadAndShare(context, mediaUrl, fileName, prefs: PrefService.of(context));
            },
          ),
        ],
      ),
    ),
  );
}

/// The highest-bitrate MP4 variant of a tweet video or GIF — the one worth
/// keeping on disk (a GIF's variant is a silent MP4, which WhatsApp accepts).
String? _largestVideoVariantUrl(Media item) {
  final variants =
      (item.videoInfo?.variants ?? const []).where((v) => v.contentType?.contains('mp4') ?? false).toList();
  variants.sort((a, b) => (b.bitrate ?? 0).compareTo(a.bitrate ?? 0));
  return variants.firstOrNull?.url;
}
