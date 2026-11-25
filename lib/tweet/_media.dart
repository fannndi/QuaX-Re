import 'package:dart_twitter_api/twitter_api.dart';
import 'package:extended_image/extended_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/library/library_model.dart';
import 'package:quax/library/library_presence.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/tweet/media_actions.dart';
import 'package:quax/tweet/media_viewer.dart';
import 'package:quax/tweet/video_metadata.dart';
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

  const _TweetMediaItem({
    required this.index,
    required this.mediaIndex,
    required this.total,
    required this.media,
    required this.username,
    this.tweetId,
  });

  @override
  State<_TweetMediaItem> createState() => _TweetMediaItemState();
}

class _TweetMediaItemState extends State<_TweetMediaItem> {
  bool _showMedia = false;

  @override
  void initState() {
    super.initState();

    var disableAutoload =
        PrefService.of(
          context,
          listen: false,
        ).get<bool>(optionMediaDisableAutoload) ??
        false;
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
      // A plain assignment: initState is already followed by a build, so a
      // setState here only marks the element dirty before the first one.
      _showMedia = true;
    }
  }

  String getMediaType(BuildContext context, String? type) {
    final l10n = L10n.of(context);
    switch (type) {
      case 'animated_gif':
        return l10n.media;
      case 'photo':
        return l10n.photos.toLowerCase();
      case 'video':
        return l10n.videos.toLowerCase();
      default:
        return l10n.unknown.toLowerCase();
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
        mediaIndex: widget.mediaIndex,
      );
    } else {
      media = GestureDetector(
        child: Container(
          color: Colors.black26,
          child: Center(
            child: Text(
              L10n.of(context).tap_to_show_getMediaType_item_type(
                getMediaType(context, item.type),
              ),
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
        ),
      ],
    );
  }
}

/// The quiet line under a media box: the total clip length on the left, and a
/// local-library marker when the exact download URL already has a file.
class _MediaMetaRow extends StatefulWidget {
  final Media media;

  const _MediaMetaRow({super.key, required this.media});

  @override
  State<_MediaMetaRow> createState() => _MediaMetaRowState();
}

class _MediaMetaRowState extends State<_MediaMetaRow> {
  LibraryModel? _library;
  String? _url;
  String _root = '';
  bool _inGallery = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    LibraryPresence.revision.addListener(_onLibraryChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshPresence();
  }

  @override
  void dispose() {
    LibraryPresence.revision.removeListener(_onLibraryChanged);
    super.dispose();
  }

  void _onLibraryChanged() => _refreshPresence(force: true);

  void _refreshPresence({bool force = false}) {
    final prefs = PrefService.of(context, listen: false);
    final root = prefs.get<String>(optionLibraryPath) ?? '';
    final url = downloadableMediaUri(
      widget.media,
      tweetMedia: true,
    )?.toString();
    if (!force && url == _url && root == _root) return;

    _url = url;
    _root = root;
    _library = LibraryModel(prefs);
    final generation = ++_generation;

    if (url == null || url.isEmpty || root.isEmpty) {
      if (_inGallery) setState(() => _inGallery = false);
      return;
    }

    LibraryPresence.contains(
      root: root,
      url: url,
      lookup: () => _library!.localPathFor(url),
    ).then((present) {
      if (!mounted || generation != _generation) return;
      if (present != _inGallery) setState(() => _inGallery = present);
    });
  }

  @override
  Widget build(BuildContext context) {
    final duration = widget.media.type == 'video'
        ? formatVideoDuration(widget.media.videoInfo?.durationMillis)
        : '';
    if (duration.isEmpty && !_inGallery) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          if (duration.isNotEmpty)
            Text(
              duration,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (duration.isNotEmpty && _inGallery) const SizedBox(width: 8),
          if (_inGallery)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.download_done,
                    size: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    L10n.of(context).label_in_gallery,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
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

  const TweetMedia({
    super.key,
    required this.sensitive,
    required this.media,
    required this.username,
    this.initialMediaIndex = 0,
    this.tweetId,
  });

  @override
  State<TweetMedia> createState() => _TweetMediaState();
}

class _TweetMediaState extends State<TweetMedia> {
  late final PageController _controller;
  late int _mediaIndex;

  @override
  void initState() {
    super.initState();
    _mediaIndex = widget.initialMediaIndex.clamp(
      0,
      widget.media.isEmpty ? 0 : widget.media.length - 1,
    );
    _controller = PageController(initialPage: _mediaIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // X sizes the gallery from its first item. reduce(min) picked the
    // narrowest ratio (the tallest box) and letterboxed every other page;
    // a missing size used to crash on the null assertions.
    final large = widget.media.isEmpty ? null : widget.media.first.sizes?.large;
    final width = large?.w ?? 1;
    final height = large?.h ?? 1;
    final aspectRatio = height == 0 ? 1.0 : width / height;

    return Consumer<TweetContextState>(
      builder: (context, model, child) {
        if (model.hideSensitive && (widget.sensitive ?? false)) {
          return Card(
            child: Center(
              child: EmojiErrorWidget(
                emoji: '🍆🙈🍆',
                message: L10n.current.possibly_sensitive,
                errorMessage: L10n.current.possibly_sensitive_tweet,
                retryText: L10n.current.yes_please,
                // This warning is part of a card, not a route: "Back" here used to
                // pop the whole feed or, at the root, close the app.
                showBackButton: false,
                onRetry: () async => model.setHideSensitive(false),
              ),
            ),
          );
        }

        final currentMedia = widget.media.isEmpty
            ? null
            : widget.media[_mediaIndex.clamp(0, widget.media.length - 1)];

        return Container(
          margin: const EdgeInsets.only(top: 8, left: 16, right: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: aspectRatio,
                child: PageView.builder(
                  controller: _controller,
                  scrollDirection: Axis.horizontal,
                  itemCount: widget.media.length,
                  onPageChanged: (index) {
                    if (index == _mediaIndex) return;
                    setState(() => _mediaIndex = index);
                  },
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
                                  tweetId: widget.tweetId,
                                ),
                              ),
                            ),
                      onLongPress: () =>
                          showMediaActionsSheet(context, item, widget.username),
                      child: _TweetMediaItem(
                        media: item,
                        index: index + 1,
                        mediaIndex: index,
                        total: widget.media.length,
                        username: widget.username,
                        tweetId: widget.tweetId,
                      ),
                    );
                  },
                ),
              ),
              if (currentMedia != null)
                _MediaMetaRow(
                  key: ValueKey('${widget.tweetId}:$_mediaIndex'),
                  media: currentMedia,
                ),
            ],
          ),
        );
      },
    );
  }
}
