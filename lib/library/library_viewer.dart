import 'package:better_player_plus/better_player_plus.dart';
import 'package:extended_image/extended_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/library/library_model.dart';

/// TikTok-style reading of the downloaded library: one full-screen media per
/// vertical page, videos auto-playing while they are on screen and paused the
/// moment they leave, images pinch-to-zoom. All file types share one feed.
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
            return _VideoPage(entry: entry, active: index == _currentPage);
          }
          return _ImagePage(entry: entry);
        },
      ),
    );
  }
}

class _VideoPage extends StatefulWidget {
  final LibraryEntry entry;
  final bool active;

  const _VideoPage({required this.entry, required this.active});

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  late final BetterPlayerController _controller = BetterPlayerController(
    const BetterPlayerConfiguration(
      fit: BoxFit.contain,
      autoPlay: true,
      looping: true,
      autoDispose: false,
      // The page decides play/pause on visibility; the library must not fight it.
      handleLifecycle: false,
      allowedScreenSleep: false,
    ),
    betterPlayerDataSource: BetterPlayerDataSource.file(widget.entry.file.path),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_VideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;

    if (widget.active) {
      _controller.play();
    } else {
      _controller.pause();
    }
  }

  @override
  Widget build(BuildContext context) {
    return BetterPlayer(controller: _controller);
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
