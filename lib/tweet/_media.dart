import 'dart:math' as math;

import 'package:dart_twitter_api/twitter_api.dart';
import 'package:extended_image/extended_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/app/design_tokens.dart';
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
  final double? aspectRatioOverride;

  const _TweetMediaItem({
    required this.index,
    required this.mediaIndex,
    required this.total,
    required this.media,
    required this.username,
    this.tweetId,
    this.aspectRatioOverride,
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
        aspectRatioOverride: widget.aspectRatioOverride,
      );
    } else {
      media = GestureDetector(
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: Center(
            child: Text(
              L10n.of(context).tap_to_show_getMediaType_item_type(
                getMediaType(context, item.type),
              ),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
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
        Positioned.fill(child: media),
        Positioned(
          top: AppSpace.sm,
          right: AppSpace.sm,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.sm,
              vertical: AppSpace.xs,
            ),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: AppRadius.smAll,
            ),
            child: Text(
              '${widget.index} / ${widget.total}',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: Colors.white),
            ),
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

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final metaStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.sm),
      child: Row(
        children: [
          if (duration.isNotEmpty) Text(duration, style: metaStyle),
          if (duration.isNotEmpty && _inGallery)
            const SizedBox(width: AppSpace.sm),
          if (_inGallery)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: AppRadius.smAll,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.download_done,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpace.xs),
                  Text(L10n.of(context).label_in_gallery, style: metaStyle),
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
          return Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.sm,
              AppSpace.lg,
              AppSpace.sm,
            ),
            child: Card(
              child: Padding(
                padding: AppSpace.card,
                child: EmojiErrorWidget(
                  emoji: '🍆🙈🍆',
                  message: L10n.current.possibly_sensitive,
                  errorMessage: L10n.current.possibly_sensitive_tweet,
                  retryText: L10n.current.yes_please,
                  // This warning is part of a card, not a route: "Back" here used
                  // to pop the whole feed or, at the root, close the app.
                  showBackButton: false,
                  onRetry: () async => model.setHideSensitive(false),
                ),
              ),
            ),
          );
        }

        final currentMedia = widget.media.isEmpty
            ? null
            : widget.media[_mediaIndex.clamp(0, widget.media.length - 1)];

        final clampedRatio = aspectRatio.clamp(0.8, 1.91).toDouble();
        final maxHeight = math.min(
          MediaQuery.sizeOf(context).height * AppSize.mediaMaxViewportFraction,
          AppSize.mediaMaxHeight,
        );

        return Container(
          margin: const EdgeInsets.only(
            top: AppSpace.sm,
            left: AppSpace.lg,
            right: AppSpace.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final height = math.min(
                    constraints.maxWidth / clampedRatio,
                    maxHeight,
                  );
                  return SizedBox(
                    height: height,
                    child: ClipRRect(
                      borderRadius: AppRadius.mdAll,
                      child: PageView.builder(
                        controller: _controller,
                        scrollDirection: Axis.horizontal,
                        itemCount: widget.media.length,
                        onPageChanged: (index) {
                          if (index == _mediaIndex) return;
                          setState(() => _mediaIndex = index);
                        },
                        itemBuilder: (context, index) {
                          final item = widget.media[index];

                          // A video has its own tap controls and must never open
                          // the fullscreen media viewer. Photos and GIFs still
                          // open it.
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
                            onLongPress: () => showMediaActionsSheet(
                              context,
                              item,
                              widget.username,
                            ),
                            child: _TweetMediaItem(
                              media: item,
                              index: index + 1,
                              mediaIndex: index,
                              total: widget.media.length,
                              username: widget.username,
                              tweetId: widget.tweetId,
                              aspectRatioOverride: clampedRatio,
                            ),
                          );
                        },
                      ),
                    ),
                  );
                },
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
