import 'dart:math' as math;

import 'package:dart_twitter_api/twitter_api.dart';
import 'package:extended_image/extended_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/tweet/media_actions.dart';
import 'package:quax/tweet/media_viewer.dart';
import 'package:quax/tweet/_video_overlays.dart';
import 'package:quax/ui/errors.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';

class _TweetMediaItem extends StatefulWidget {
  final int index;
  final int mediaIndex;
  final int total;
  final Media media;
  final String username;
  final String? tweetId;

  const _TweetMediaItem(
      {required this.index,
      required this.mediaIndex,
      required this.total,
      required this.media,
      required this.username,
      this.tweetId});

  @override
  State<_TweetMediaItem> createState() => _TweetMediaItemState();
}

class _TweetMediaItemState extends State<_TweetMediaItem> {
  bool _showMedia = false;

  @override
  void initState() {
    super.initState();

    var disableAutoload = PrefService.of(context, listen: false).get<bool>(optionMediaDisableAutoload) ?? false;
    if (disableAutoload) {
      // If the image is cached already, show the media
      cachedImageExists(widget.media.mediaUrlHttps!).then((value) {
        if (mounted) {
          setState(() {
            _showMedia = value;
          });
        }
      });
    } else {
      setState(() {
        _showMedia = true;
      });
    }
  }

  String getMediaType(String? type) {
    switch (type) {
      case 'animated_gif':
        return 'GIF';
      case 'photo':
        return 'photo';
      case 'video':
        return 'video';
      default:
        return 'media';
    }
  }

  @override
  Widget build(BuildContext context) {
    var prefs = PrefService.of(context, listen: false);
    var size = prefs.get(optionImageQuality);

    Widget media;

    var item = widget.media;

    if (_showMedia) {
      media = TweetMediaThing(
          item: item,
          username: widget.username,
          size: size,
          pullToClose: false,
          inPageView: false,
          tweetId: widget.tweetId,
          mediaIndex: widget.mediaIndex);
    } else {
      media = GestureDetector(
        child: Container(
          color: Colors.black26,
          child: Center(
            child: Text(
              L10n.of(context).tap_to_show_getMediaType_item_type(getMediaType(item.type)),
            ),
          ),
        ),
        onTap: () => setState(() {
          _showMedia = true;
        }),
      );
    }

    // If there's only one item in this media collection, don't show the page counter
    if (widget.total == 1) {
      return media;
    }

    return Stack(
      children: [
        Center(child: media),
        Positioned(
          right: 0,
          child: Container(
            alignment: Alignment.topRight,
            color: Colors.black38,
            margin: const EdgeInsets.all(8),
            padding: const EdgeInsets.all(8),
            child: Text('${widget.index} / ${widget.total}'),
          ),
        )
      ],
    );
  }
}

class TweetMedia extends StatefulWidget {
  final bool? sensitive;
  final List<Media> media;
  final String username;
  final int initialMediaIndex;
  // Used (with the media index) to cache/reuse video controllers across screens.
  final String? tweetId;

  const TweetMedia(
      {super.key,
      required this.sensitive,
      required this.media,
      required this.username,
      this.initialMediaIndex = 0,
      this.tweetId});

  @override
  State<TweetMedia> createState() => _TweetMediaState();
}

class _TweetMediaState extends State<TweetMedia> {
  late final PageController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: widget.initialMediaIndex);
  }

  @override
  Widget build(BuildContext context) {
    var largestAspectRatio =
    widget.media.map((e) => ((e.sizes!.large!.w) ?? 1) / ((e.sizes!.large!.h) ?? 1)).reduce(math.min);

    return Consumer<TweetContextState>(builder: (context, model, child) {
      if (model.hideSensitive && (widget.sensitive ?? false)) {
        return Card(
          child: Center(
              child: EmojiErrorWidget(
            emoji: '🍆🙈🍆',
            message: L10n.current.possibly_sensitive,
            errorMessage: L10n.current.possibly_sensitive_tweet,
            retryText: L10n.current.yes_please,
            onRetry: () async => model.setHideSensitive(false),
          )),
        );
      }

      return Container(
        margin: const EdgeInsets.only(top: 8, left: 16, right: 16),
        child: AspectRatio(
          aspectRatio: largestAspectRatio,
          child: PageView.builder(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            itemCount: widget.media.length,
            itemBuilder: (context, index) {
              var item = widget.media[index];

              // A video has its own tap controls and must never open the
              // fullscreen media viewer. Photos and GIFs still open it.
              final isVideo = item.type == 'video';

              return GestureDetector(
                onTap: isVideo
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (context) => TweetMediaView(
                                initialIndex: index,
                                media: widget.media,
                                username: widget.username,
                                tweetId: widget.tweetId))),
                onLongPress: () => showMediaActionsSheet(context, item, widget.username),
                child: Stack(
                  children: [
                    _TweetMediaItem(
                        media: item,
                        index: index + 1,
                        mediaIndex: index,
                        total: widget.media.length,
                        username: widget.username,
                        tweetId: widget.tweetId),
                    // Every video carries its length, exactly like the X app.
                    if (isVideo)
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: VideoDurationBadge(durationMillis: item.videoInfo?.durationMillis),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    });
  }
}


