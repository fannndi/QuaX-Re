import 'package:material_ui/material_ui.dart';
import 'package:quax/tweet/_video_controls.dart';
import 'package:quax/tweet/video_metadata.dart';

/// A small "GIF" label, shown over a GIF that is displayed statically (not
/// animating — e.g. a grid cell the playback gate didn't grant, or a GIF whose
/// hardware decoder couldn't be allocated) so it's clear it's an animated GIF.
class GifBadge extends StatelessWidget {
  const GifBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'GIF',
        style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold, height: 1.0),
      ),
    );
  }
}

class FritterCenterPlayButton extends StatelessWidget {
  const FritterCenterPlayButton({
    super.key,
    required this.backgroundColor,
    this.iconColor,
    required this.show,
    required this.isPlaying,
    required this.isFinished,
    this.onPressed,
    this.size = 64.0,
  });

  final Color backgroundColor;
  final Color? iconColor;
  final bool show;
  final bool isPlaying;
  final bool isFinished;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.transparent,
      child: Center(
        child: AnimatedOpacity(
          opacity: show ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 300),
          child: GestureDetector(
            onTap: onPressed,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: backgroundColor,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                iconSize: size / 2,
                icon: isFinished
                    ? Icon(Icons.replay, color: iconColor)
                    : AnimatedPlayPause(playing: isPlaying, color: iconColor, size: size / 2),
                onPressed: onPressed,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
/// The small duration chip X shows in the corner of every video.
class VideoDurationBadge extends StatelessWidget {
  final int? durationMillis;

  const VideoDurationBadge({super.key, required this.durationMillis});

  @override
  Widget build(BuildContext context) {
    final label = formatVideoDuration(durationMillis);
    if (label.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}
