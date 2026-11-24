import 'package:dart_twitter_api/twitter_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/client.dart';
import 'package:quax/profile/media_grid/media_grid_items/media_grid_item.dart';
import 'package:quax/profile/profile_paging.dart';

TweetChain chain(String id) =>
    TweetChain(id: id, tweets: const [], isPinned: false);

MediaGridItem media(String tweetId, int index, {String? mediaId}) =>
    PhotoGridItem(
      tweetId: tweetId,
      username: 'author',
      thumbnailUrl: 'https://pbs.twimg.com/$tweetId-$index.jpg',
      aspectRatio: 1,
      mediaIndex: index,
      media: Media()
        ..idStr = mediaId
        ..type = 'photo'
        ..mediaUrlHttps = 'https://pbs.twimg.com/$tweetId-$index.jpg',
    );

void main() {
  test('Should dedupe overlapping profile tweet pages without changing server order', () {
    final seen = <String>{};

    final first = uniqueTweetChains([chain('a'), chain('b'), chain('a')], seen);
    final second = uniqueTweetChains([
      chain('b'),
      chain('c'),
      chain('b'),
      chain('d'),
    ], seen);

    expect(
      first.map((item) => item.id),
      ['a', 'b'],
      reason: 'The first occurrence in server order wins, including duplicates within one page',
    );
    expect(
      second.map((item) => item.id),
      ['c', 'd'],
      reason: 'An overlap at the start or middle of a page must not suppress the fresh chains after it',
    );
    expect(
      seen,
      {'a', 'b', 'c', 'd'},
      reason: 'Later pages need the full identity set, not only the identities from the last page',
    );
  });

  test('Should dedupe profile media by tweet and media identity', () {
    final seen = <({String tweetId, Object mediaId})>{};
    final first = uniqueMediaItems([
      media('tweet-a', 0, mediaId: 'photo-1'),
      media('tweet-a', 1, mediaId: 'photo-2'),
    ], seen);
    final second = uniqueMediaItems([
      media('tweet-a', 1, mediaId: 'photo-2'),
      media('tweet-b', 0, mediaId: 'photo-1'),
      media('tweet-a', 0, mediaId: 'photo-1'),
    ], seen);

    expect(
      first,
      hasLength(2),
      reason: 'Two different photos on one tweet are distinct media',
    );
    expect(
      second.map((item) => item.identity),
      [(tweetId: 'tweet-b', mediaId: 'photo-1')],
      reason: 'The same media id on another tweet is distinct, while repeated tweet/media pairs are dropped',
    );
  });

  test('Should reject an older refresh without contaminating the current chain window', () {
    final window = ProfilePageWindow<String>((id) => id);
    final staleGeneration = window.capture();
    window.invalidate();
    final currentGeneration = window.capture();

    final current = window.apply(
      ['fresh', 'fresh'],
      generation: currentGeneration,
      firstPage: true,
    );
    final stale = window.apply(
      ['stale'],
      generation: staleGeneration,
      firstPage: true,
    );
    final next = window.apply(
      ['stale', 'fresh', 'new'],
      generation: currentGeneration,
      firstPage: false,
    );

    expect(current, [
      'fresh',
    ], reason: 'The newer refresh establishes the visible first page');
    expect(
      stale,
      isEmpty,
      reason: 'An older refresh completing late must not clear or repopulate the seen set',
    );
    expect(
      next,
      ['stale', 'new'],
      reason:
          'The next page must still be allowed to contain an id seen only in the '
          'discarded refresh; otherwise that post disappears from the profile',
    );
  });

  test('Should protect media identities from an older refresh too', () {
    final window = ProfilePageWindow<MediaGridItem>((item) => item.identity);
    final staleGeneration = window.capture();
    window.invalidate();
    final currentGeneration = window.capture();
    final currentMedia = media('tweet-current', 0, mediaId: 'current-photo');
    final staleMedia = media('tweet-stale', 0, mediaId: 'stale-photo');
    final newMedia = media('tweet-new', 0, mediaId: 'new-photo');

    window.apply(
      [currentMedia],
      generation: currentGeneration,
      firstPage: true,
    );
    final stale = window.apply(
      [staleMedia],
      generation: staleGeneration,
      firstPage: true,
    );
    final next = window.apply(
      [staleMedia, currentMedia, newMedia],
      generation: currentGeneration,
      firstPage: false,
    );

    expect(
      stale,
      isEmpty,
      reason: 'The media grid shares the same refresh race as the tweet feed',
    );
    expect(
      next.map((item) => item.identity),
      [staleMedia.identity, newMedia.identity],
      reason: 'A stale refresh must not make a genuinely new media item look duplicate',
    );
  });

  test('Should use the media index when X omits a media id', () {
    final seen = <({String tweetId, Object mediaId})>{};

    uniqueMediaItems([media('tweet-a', 0)], seen);
    final fresh = uniqueMediaItems([
      media('tweet-a', 0),
      media('tweet-a', 1),
    ], seen);

    expect(
      fresh.map((item) => item.identity),
      [(tweetId: 'tweet-a', mediaId: 1)],
      reason: 'Sparse media entities still need a stable identity so overlapping pages do not repeat them',
    );
  });
}
