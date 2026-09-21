
import 'package:async_button_builder/async_button_builder.dart';
import 'package:dart_twitter_api/twitter_api.dart';
import 'package:extended_image/extended_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/tweet/_photo.dart';
import 'package:quax/tweet/_video.dart';
import 'package:quax/utils/downloads.dart';
import 'package:quax/utils/image_decode.dart';
import 'package:path/path.dart' as path;
import 'package:pref/pref.dart';

class TweetMediaView extends StatefulWidget {
  final int initialIndex;
  final List<Media> media;
  final String username;
  final bool tweetMedia;  // True if the media comes from a tweet
  final String? tweetId;

  const TweetMediaView(
      {super.key,
      required this.initialIndex,
      required this.media,
      required this.username,
      this.tweetMedia = true,
      this.tweetId});

  @override
  State<TweetMediaView> createState() => _TweetMediaViewState();
}

Media createMediaFromUrl(String? url, double? height) {
  Media media = Media();
  if (url != null) {
    ExtendedImage.network(url, fit: BoxFit.fitWidth, height: height);
    media.url = url;
    media.mediaUrlHttps = url;
    media.displayUrl = url;
    media.expandedUrl = url;
    media.type = 'photo';
  }
  return media;
}

class _TweetMediaViewState extends State<TweetMediaView> {
  late Media _media;

  @override
  void initState() {
    super.initState();

    _media = widget.media[widget.initialIndex];
  }

  String originalMediaUrl() {
    return (widget.tweetMedia ? '${_media.mediaUrlHttps}:orig' : _media.mediaUrlHttps) ?? "";
  }

  @override
  Widget build(BuildContext context) {
    String? size;
    var prefs = PrefService.of(context, listen: false);
    if (widget.tweetMedia) {
      var size = prefs.get(optionImageQuality);
      if (size == 'disabled') {
        size = 'medium';
      }
    }

    return Scaffold(
      appBar: AppBar(
        actions: [
          AsyncButtonBuilder(
            child: const Icon(Icons.download),
            builder: (context, child, callback, buttonState) {
              return IconButton(onPressed: callback, icon: child);
            },
            onPressed: () async {
              var url = path.basename(_media.mediaUrlHttps!);
              var fileName = '${widget.username}-$url';
              var uri = Uri.parse(originalMediaUrl());

              await downloadUriToPickedFile(context, uri, fileName, prefs: prefs);
            },
          ),
          AsyncButtonBuilder(
            showSuccess: false,
            builder: (context, child, callback, buttonState) {
              return IconButton(onPressed: callback, icon: child);
            },
            onPressed: () async {
              var url = path.basename(_media.mediaUrlHttps!);
              var fileName = '${widget.username}-$url';
              var uri = Uri.parse(originalMediaUrl());

              await downloadAndShare(context, uri, fileName, prefs: prefs);
            },
            child: const Icon(Icons.share),
          ),
        ],
      ),
      body: ExtendedImageGesturePageView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: widget.media.length,
        itemBuilder: (BuildContext context, int index) {
          var item = widget.media[index];

          return TweetMediaThing(
              item: item,
              username: widget.username,
              size: size,
              pullToClose: true,
              inPageView: true,
              tweetId: widget.tweetId,
              mediaIndex: index);
        },
        controller: ExtendedPageController(
          initialPage: widget.initialIndex,
        ),
        onPageChanged: (index) => setState(() {
          _media = widget.media[index];
        }),
      ),
    );
  }
}

class TweetMediaThing extends StatelessWidget {
  final Media item;
  final String username;
  final String? size;
  final bool pullToClose;
  final bool inPageView;
  final String? tweetId;
  final int mediaIndex;

  const TweetMediaThing(
      {required this.item,
      required this.username,
      required this.size,
      required this.pullToClose,
      required this.inPageView,
      this.tweetId,
      this.mediaIndex = 0});

  @override
  Widget build(BuildContext context) {
    Widget media;
    if (item.type == 'animated_gif') {
      media = TweetVideo(
          metadata: TweetVideoMetadata.fromMedia(item),
          loop: true,
          username: username,
          alwaysPlay: true,
          disableControls: true,
          tweetId: tweetId,
          mediaIndex: mediaIndex);
    } else if (item.type == 'video') {
      media = TweetVideo(
          metadata: TweetVideoMetadata.fromMedia(item),
          loop: false,
          username: username,
          tweetId: tweetId,
          mediaIndex: mediaIndex);
    } else if (item.type == 'photo') {
      media = TweetPhoto(
          size: size,
          uri: item.mediaUrlHttps!,
          fit: BoxFit.contain,
          pullToClose: pullToClose,
          inPageView: inPageView,
          // The feed copy only ever shows at viewport width; the fullscreen
          // page keeps the full decode so zooming stays sharp.
          cacheWidth: inPageView ? null : decodeWidthFor(context, MediaQuery.sizeOf(context).width - 32));
    } else {
      media = Text(L10n.of(context).unknown);
    }

    return media;
  }
}

/// Long-press actions for a single tweet-card media: download it under the
/// streamed progress dialog, or open the share sheet right away.
