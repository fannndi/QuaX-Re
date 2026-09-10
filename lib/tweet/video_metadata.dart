import 'package:dart_twitter_api/twitter_api.dart';
import 'package:quax/tweet/video_quality.dart';
import 'package:quax/utils/iterables.dart';
class TweetVideoUrls {
  final String streamUrl;
  final String? downloadUrl;
  final List<TweetVideoQuality> qualities;

  TweetVideoUrls(this.streamUrl, this.downloadUrl, {this.qualities = const []});
}

class TweetVideoMetadata {
  final double aspectRatio;
  final String? imageUrl;
  final Future<TweetVideoUrls> Function() streamUrlsBuilder;

  TweetVideoMetadata(this.aspectRatio, this.imageUrl, this.streamUrlsBuilder);

  static Future<TweetVideoUrls> Function() streamUrlsBuilderFromVariants(List<Variant> variants) {
    // Use the progressive MP4 variants (highest bitrate first), not X's HLS
    // master playlist (variants[0]): the MP4 list is what powers the in-player
    // quality picker. Fall back to variants[0] only when no MP4 exists (e.g.
    // live broadcasts), which the player handles over HLS natively.
    var mp4Variants = variants
        .where((e) => e.bitrate != null)
        .where((e) => e.url != null)
        .where((e) => e.contentType == 'video/mp4')
        .sorted((a, b) => -(a.bitrate!.compareTo(b.bitrate!)))
        .toList();

    var qualities =
        mp4Variants.map((e) => TweetVideoQuality(e.url!, _qualityLabel(e.url!, e.bitrate))).toList();

    var mp4Url = qualities.isNotEmpty ? qualities.first.url : null;
    var streamUrl = mp4Url ?? variants.firstWhereOrNull((e) => e.url != null)?.url ?? '';

    return () async => TweetVideoUrls(streamUrl, mp4Url, qualities: qualities);
  }

  // Resolution tag from X's MP4 URL path (`.../1280x720/...`), else the bitrate.
  static String _qualityLabel(String url, int? bitrate) {
    var match = RegExp(r'/(\d+)x(\d+)/').firstMatch(url);
    if (match != null) {
      return '${match.group(2)}p';
    }
    if (bitrate != null) {
      return '${(bitrate / 1000000).toStringAsFixed(1)} Mbps';
    }
    return '—';
  }

  factory TweetVideoMetadata.fromMedia(Media media) {
    var aspectRatio = media.videoInfo?.aspectRatio == null
        ? 1.0
        : media.videoInfo!.aspectRatio![0] / media.videoInfo!.aspectRatio![1];

    var variants = media.videoInfo?.variants ?? [];
    var imageUrl = media.mediaUrlHttps!;

    return TweetVideoMetadata(aspectRatio, imageUrl, streamUrlsBuilderFromVariants(variants));
  }
}
