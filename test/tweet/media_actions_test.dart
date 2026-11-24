import 'package:dart_twitter_api/twitter_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quax/tweet/media_actions.dart';

Media video({List<Variant>? variants}) => Media()
  ..type = 'video'
  ..mediaUrlHttps = 'https://pbs.twimg.com/ext_tw_video_thumb/pu/img/thumb.jpg'
  ..videoInfo = (VideoInfo()..variants = variants);

Variant variant(String url, int bitrate, String contentType) => Variant()
  ..url = url
  ..bitrate = bitrate
  ..contentType = contentType;

void main() {
  group('downloadableMediaUri()', () {
    test('Should use :orig only for photos that came from a tweet', () {
      final photo = Media()
        ..type = 'photo'
        ..mediaUrlHttps = 'https://pbs.twimg.com/media/photo.jpg';

      expect(
        downloadableMediaUri(photo, tweetMedia: true)?.toString(),
        'https://pbs.twimg.com/media/photo.jpg:orig',
        reason: 'The original photo is the full-resolution copy worth saving',
      );
      expect(
        downloadableMediaUri(photo, tweetMedia: false)?.toString(),
        'https://pbs.twimg.com/media/photo.jpg',
        reason:
            'A profile banner or avatar is already a direct URL; appending :orig '
            'asks X for a variant that does not exist',
      );
    });

    test('Should use the highest-bitrate MP4 for videos and GIFs', () {
      final clip = video(
        variants: [
          variant(
            'https://video.twimg.com/clip.m3u8',
            0,
            'application/x-mpegURL',
          ),
          variant('https://video.twimg.com/480p.mp4', 832000, 'video/mp4'),
          variant('https://video.twimg.com/1080p.mp4', 2176000, 'video/mp4'),
        ],
      );
      clip.type = 'animated_gif';

      expect(
        downloadableMediaUri(clip, tweetMedia: true)?.toString(),
        'https://video.twimg.com/1080p.mp4',
        reason:
            'A GIF is stored as its silent MP4, and download/share must not use the '
            'thumbnail URL or append the photo-only :orig suffix',
      );
    });

    test('Should return no URL for an HLS-only clip', () {
      final clip = video(
        variants: [
          variant(
            'https://video.twimg.com/master.m3u8',
            0,
            'application/x-mpegURL',
          ),
        ],
      );

      expect(
        downloadableMediaUri(clip, tweetMedia: true),
        isNull,
        reason:
            'An HLS playlist is not a downloadable file; offering it would save a '
            'playlist instead of the video',
      );
    });

    test('Should return no URL when the media itself has no URL', () {
      expect(
        downloadableMediaUri(Media()..type = 'photo', tweetMedia: true),
        isNull,
        reason:
            'A malformed media entity must disable the actions instead of crashing '
            'on a null assertion',
      );
    });
  });
}
