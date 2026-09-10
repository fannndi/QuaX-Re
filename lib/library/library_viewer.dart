import 'dart:io';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:extended_image/extended_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/library/library_model.dart';

/// TikTok-style reading of the downloaded library: one full-screen media per
/// vertical page, videos auto-playing while they are on screen and paused,
/// seeking to the saved position (Hentoid's resume-reading), and advancing to
/// the next page on playback end. Images pinch-to-zoom.
class LibraryViewer extends StatefulWidget {
  final LibraryModel model;
  final int initialIndex;

  const LibraryViewer({super.key, required this.model, required this.initialIndex});

  @override
  State<LibraryViewer> createState() => _LibraryViewerState();
}

class _LibraryViewerState extends State<LibraryViewer> {
  late final PageController _pageController = PageController(initialPage: widget.initialIndex);
  late int _currentPage = widget.initialIndex;

  void _advance() {
    if (!mounted) return;
    final next = _currentPage + 1;
    if (next >= widget.model.state.length) return;
    _pageController.animateToPage(next, duration: const Duration(milliseconds: 400), curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.model.state;
    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView.builder(
        controller: _pageController,
        scrollDirection: Axis.vertical,
        itemCount: entries.length,
        onPageChanged: (index) {
          setState(() {
            _currentPage = index;
          });
        },
        itemBuilder: (context, index) {
          final entry = entries[index];
          if (entry.isVideo) {
            return _VideoPage(
                model: widget.model,
                entry: entry,
                active: index == _currentPage,
                onEnded: () async {
                  widget.model.savePosition(entry, 0);
                  _advance();
                });
          }
          return _ImagePage(entry: entry);
        },
      ),
    );
  }
}

class _VideoPage extends StatefulWidget {
  final LibraryModel model;
  final LibraryEntry entry;
  final bool active;
  final Future<void> Function()? onEnded;

  const _VideoPage({required this.model, required this.entry, required this.active, this.onEnded});

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  BetterPlayerController? _controller;
  bool? _didSeekToSaved;
  // The video frame shows under the player until playback actually starts, so
  // a downloaded clip never greets the reader with a black screen.
  bool _showPoster = true;
  BetterPlayerConfiguration get _configuration => const BetterPlayerConfiguration(
        fit: BoxFit.contain,
        autoPlay: true,
        looping: false,
        autoDispose: false,
        // The page decides play/pause on visibility; the library must not
        // fight it.
        handleLifecycle: false,
        allowedScreenSleep: false,
      );

  void _attachEvents(BetterPlayerController controller) {
    controller.addEventsListener((event) async {
      switch (event.betterPlayerEventType) {
        case BetterPlayerEventType.play:
          if (_showPoster && mounted) {
            setState(() => _showPoster = false);
          }
          break;
        case BetterPlayerEventType.finished:
          _didSeekToSaved = true;
          widget.model.savePosition(widget.entry, 0);
          await widget.onEnded?.call();
          break;
        case BetterPlayerEventType.initialized:
          // Re-read the saved playback offset exactly once per data source;
          // a plain seekTo after initialization lands cleanly.
          if (_didSeekToSaved != null) return;
          _didSeekToSaved = false;
          final savedMs = widget.model.positionFor(widget.entry) ?? 0;
          if (savedMs > 5000) {
            // Seek to the last stop point: five seconds before the end is a
            // natural restart edge.
            final durationMs = _controller!.videoPlayerController?.value.duration?.inMilliseconds ?? 0;
            if (savedMs < durationMs - 5000) {
              _didSeekToSaved = true;
              _controller?.seekTo(Duration(milliseconds: savedMs));
            }
          }
          break;
        default:
          break;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _buildController();
  }

  void _buildController() {
    _controller = BetterPlayerController(_configuration);
    _attachEvents(_controller!);
    _controller!.setupDataSource(BetterPlayerDataSource.file(widget.entry.file.path));
  }

  /// Saves the current playback offset when a page leaves visibility.
  Future<void> _saveCurrentPosition() async {
    final value = _controller?.videoPlayerController?.value;
    if (value == null) return;
    final positionMs = value.position.inMilliseconds ?? 0;
    if (positionMs <= 0) return;
    // A fully watched video falls back to a fresh start next time.
    final durationMs = value.duration?.inMilliseconds ?? 0;
    if (durationMs > 0 && positionMs > durationMs - 5000) {
      widget.model.savePosition(widget.entry, 0);
      return;
    }
    widget.model.savePosition(widget.entry, positionMs);
  }

  @override
  void dispose() {
    _saveCurrentPosition();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_VideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;

    if (widget.active) {
      _controller?.play();
    } else {
      _saveCurrentPosition();
      _controller?.pause();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        BetterPlayer(controller: _controller!),
        if (_showPoster)
          FutureBuilder<String?>(
            future: widget.model.thumbnailFor(widget.entry),
            builder: (context, snapshot) {
              final poster = snapshot.data;
              if (poster == null) {
                return const SizedBox.shrink();
              }
              return IgnorePointer(
                child: ColoredBox(
                  color: Colors.black,
                  child: ExtendedImage.file(File(poster), fit: BoxFit.contain),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// A viewed downloaded image: pin-to-zoom with the same gesture set the tweet
/// photos use.
class _ImagePage extends StatelessWidget {
  final LibraryEntry entry;

  const _ImagePage({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: ExtendedImage.file(
        entry.file,
        fit: BoxFit.contain,
        mode: ExtendedImageMode.gesture,
        initGestureConfigHandler: (state) {
          return GestureConfig(
            inPageView: true,
            minScale: 0.9,
            animationMinScale: 0.7,
            maxScale: 4.0,
            animationMaxScale: 4.0,
            speed: 1.0,
            inertialSpeed: 100.0,
            initialScale: 1.0,
            initialAlignment: InitialAlignment.center,
          );
        },
      ),
    );
  }
}

