import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/client.dart';
import 'package:quax/utils/image_prefetch.dart';

Map<String, dynamic> payload(Object o) => jsonDecode(jsonEncode(o)) as Map<String, dynamic>;

/// One timeline entry holding a post with the given photographs, and any videos
/// alongside them. The payload mirrors what X returns: the media live under the
/// `legacy` object, which is where `TweetWithCard.fromData` reads them from.
Map<String, dynamic> entryWithMedia(String id, List<String> photos, {List<String> videos = const []}) {
  final media = [
    for (final photo in photos) {'type': 'photo', 'media_url_https': photo},
    for (final video in videos)
      {'type': 'video', 'media_url_https': video, 'video_info': {'duration_millis': 1000}},
  ];

  return payload({
    'entryId': 'tweet-$id',
    'content': {
      'itemContent': {
        'tweet_results': {
          'result': {
            'rest_id': id,
            'legacy': {
              'id_str': id,
              'full_text': 'a post with media',
              'created_at': 'Wed Oct 11 00:00:00 +0000 2017',
              'extended_entities': {'media': media},
            },
          }
        }
      }
    }
  });
}

void main() {
  List<TweetChain> chainsOf(List<Map<String, dynamic>> entries) => createTweets(entries);

  group('warmableImageUrls()', () {
    test('Should carry the suffix the cards will ask for', () {
      final chains = chainsOf([
        entryWithMedia('1', ['https://pbs.twimg.com/media/a.jpg']),
      ]);

      expect(warmableImageUrls(chains, ':small', 8), ['https://pbs.twimg.com/media/a.jpg:small'],
          reason: 'The warm-up has to land in the exact cache entry the card is about to read, so '
              'it asks for the same variant and quality the card will');
    });

    test('Should skip videos and warm only the photographs', () {
      final chains = chainsOf([
        entryWithMedia('1', ['https://pbs.twimg.com/media/a.jpg'],
            videos: ['https://video.twimg.com/a.mp4']),
      ]);

      expect(warmableImageUrls(chains, '', 8), ['https://pbs.twimg.com/media/a.jpg'],
          reason: 'A video here would go through the auto-cache, not the image cache, so warming '
              'it would spend data on a fetch the player does not read from');
    });

    test('Should stop at the limit instead of warming every picture', () {
      final chains = chainsOf([
        entryWithMedia('1', ['https://pbs.twimg.com/media/a.jpg', 'https://pbs.twimg.com/media/b.jpg']),
        entryWithMedia('2', ['https://pbs.twimg.com/media/c.jpg']),
      ]);

      expect(warmableImageUrls(chains, '', 2), hasLength(2),
          reason: 'Prefetching is meant to warm what is about to come on screen, not the whole '
              'page — fetching everything would spend the same data the spinner was avoiding');
    });

    test('Should return nothing when the page carries no media', () {
      final chains = chainsOf([entryWithMedia('1', const [])]);

      expect(warmableImageUrls(chains, '', 8), isEmpty,
          reason: 'A text-only page has nothing to warm, and calling the image pipeline for it '
              'would be pointless work');
    });

    test('Should return nothing for an empty page', () {
      expect(warmableImageUrls(const [], '', 8), isEmpty,
          reason: 'The loader can hand over an empty list while a page loads; it must not throw');
    });
  });
}
