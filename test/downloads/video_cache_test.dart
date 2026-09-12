import 'package:flutter_test/flutter_test.dart';
import 'package:quax/downloads/video_cache.dart';

void main() {
  group('isEligibleDuration()', () {
    test('Should accept clips up to five minutes included', () {
      expect(VideoCache.isEligibleDuration(4 * 60 * 1000), isTrue,
          reason: 'A four-minute clip is well within the auto-cache budget');
      expect(VideoCache.isEligibleDuration(5 * 60 * 1000), isTrue,
          reason: 'The five-minute boundary itself must qualify: "under 5 minutes" includes it');
    });

    test('Should refuse longer or unknown durations', () {
      expect(VideoCache.isEligibleDuration(5 * 60 * 1000 + 1), isFalse,
          reason: 'A clip longer than five minutes must never be cached automatically');
      expect(VideoCache.isEligibleDuration(null), isFalse,
          reason: 'Without a duration there is no way to keep the cache bounded by size and time');
      expect(VideoCache.isEligibleDuration(0), isFalse,
          reason: 'A zero duration is a parsing artefact, not a tiny clip');
    });
  });

  group('planEviction()', () {
    VideoCacheEntry entry(String name, int size, int at) =>
        VideoCacheEntry(name: name, url: name, size: size, touchedAt: at);

    test('Should keep everything when the total fits the cap', () {
      final entries = [entry('a', 100, 1), entry('b', 100, 2)];

      expect(VideoCache.planEviction(entries, 1000), isEmpty,
          reason: 'Nothing should be deleted while the cache is under its limit');
    });

    test('Should evict the least recently touched entries first', () {
      final entries = [entry('old', 300, 1), entry('mid', 300, 2), entry('new', 300, 3)];

      expect(VideoCache.planEviction(entries, 700), ['old'],
          reason: 'Dropping one entry must free just enough and pick the coldest one');
    });

    test('Should evict everything when the cap is zero', () {
      final entries = [entry('a', 100, 1), entry('b', 200, 2)];

      expect(VideoCache.planEviction(entries, 0), containsAll(<String>['a', 'b']),
          reason: 'A zero limit means the cache is off and every file goes');
    });

    test('Should handle an empty cache', () {
      expect(VideoCache.planEviction([], 1000), isEmpty,
          reason: 'Planning on an empty cache must not throw');
    });
  });

  group('fileNameFor()', () {
    test('Should strip the query string and unsafe characters', () {
      expect(
          VideoCache.fileNameFor('https://video.twimg.com/foo/bar clip.mp4?tag=12'),
          'bar_clip.mp4',
          reason: 'The cached name must match what the download flow can find again from the URL');
    });

    test('Should keep the tail of very long names within file-system limits', () {
      final long = '${'a' * 200}.mp4';

      final name = VideoCache.fileNameFor('https://video.twimg.com/$long');

      expect(name.length, lessThanOrEqualTo(120),
          reason: 'Android file names are bounded; the cache must not build names that fail to write');
      expect(name.endsWith('.mp4'), isTrue,
          reason: 'The extension survives so matching a cached file back to the URL still works');
    });
  });
}
