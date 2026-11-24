import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';
import 'package:quax/downloads/video_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isEligibleDuration()', () {
    test('Should accept clips up to five minutes included', () {
      expect(
        VideoCache.isEligibleDuration(4 * 60 * 1000),
        isTrue,
        reason: 'A four-minute clip is well within the auto-cache budget',
      );
      expect(
        VideoCache.isEligibleDuration(5 * 60 * 1000),
        isTrue,
        reason: 'The five-minute boundary itself must qualify: "under 5 minutes" includes it',
      );
    });

    test('Should refuse longer or unknown durations', () {
      expect(
        VideoCache.isEligibleDuration(5 * 60 * 1000 + 1),
        isFalse,
        reason: 'A clip longer than five minutes must never be cached automatically',
      );
      expect(
        VideoCache.isEligibleDuration(null),
        isFalse,
        reason: 'Without a duration there is no way to keep the cache bounded by size and time',
      );
      expect(
        VideoCache.isEligibleDuration(0),
        isFalse,
        reason: 'A zero duration is a parsing artefact, not a tiny clip',
      );
    });
  });

  group('planEviction()', () {
    VideoCacheEntry entry(String name, int size, int at) =>
        VideoCacheEntry(name: name, url: name, size: size, touchedAt: at);

    test('Should keep everything when the total fits the cap', () {
      final entries = [entry('a', 100, 1), entry('b', 100, 2)];

      expect(
        VideoCache.planEviction(entries, 1000),
        isEmpty,
        reason: 'Nothing should be deleted while the cache is under its limit',
      );
    });

    test('Should evict the least recently touched entries first', () {
      final entries = [
        entry('old', 300, 1),
        entry('mid', 300, 2),
        entry('new', 300, 3),
      ];

      expect(
        VideoCache.planEviction(entries, 700),
        ['old'],
        reason:
            'Dropping one entry must free just enough and pick the coldest one',
      );
    });

    test('Should evict everything when the cap is zero', () {
      final entries = [entry('a', 100, 1), entry('b', 200, 2)];

      expect(
        VideoCache.planEviction(entries, 0),
        containsAll(<String>['a', 'b']),
        reason: 'A zero limit means the cache is off and every file goes',
      );
    });

    test('Should handle an empty cache', () {
      expect(
        VideoCache.planEviction([], 1000),
        isEmpty,
        reason: 'Planning on an empty cache must not throw',
      );
    });
  });

  group('fileNameFor()', () {
    test(
      'Should hash the canonical full URL so query variants cannot collide',
      () {
        final first = VideoCache.fileNameFor(
          'https://video.twimg.com/clip.mp4?tag=12',
        );
        final second = VideoCache.fileNameFor(
          'https://video.twimg.com/clip.mp4?tag=13',
        );

        expect(
          first,
          isNot(second),
          reason: 'The query can select a different encode; a basename key overwrote one clip with another',
        );
        expect(
          first.endsWith('.mp4'),
          isTrue,
          reason: 'The extension survives for viewers and storage reports',
        );
      },
    );

    test('Should normalize URL ordering and fragments without dropping query identity', () {
      expect(
        VideoCache.fileNameFor(
          'https://VIDEO.twimg.com/clip.mp4?b=2&a=1#fragment',
        ),
        VideoCache.fileNameFor('https://video.twimg.com:443/clip.mp4?a=1&b=2'),
        reason: 'Equivalent canonical URLs should share one cache entry',
      );
    });

    test(
      'Should keep very long URL-derived names within file-system limits',
      () {
        final name = VideoCache.fileNameFor(
          'https://video.twimg.com/${'a' * 200}.mp4?x=1',
        );

        expect(
          name.length,
          lessThanOrEqualTo(120),
          reason: 'Android file names are bounded; hashing must not build names that fail to write',
        );
        expect(name.endsWith('.mp4'), isTrue);
      },
    );
  });

  group('URL mapping and migration', () {
    late Directory root;
    final prefs = PrefServiceCache(cache: {optionVideoCacheLimitMb: 1024});

    setUp(() async {
      root = await Directory.systemTemp.createTemp('quax-video-cache-');
      VideoCache.debugDirectoryOverride = root;
      VideoCache().resetForTests();
    });

    tearDown(() async {
      VideoCache().resetForTests();
      VideoCache.debugDirectoryOverride = null;
      await root.delete(recursive: true);
    });

    test(
      'Should keep two same-basename URLs as separate exact mappings',
      () async {
        final incoming = File(p.join(root.path, 'incoming'))
          ..writeAsBytesSync([1]);
        await VideoCache().put(
          'https://video.twimg.com/clip.mp4?tag=1',
          incoming,
          prefs: prefs,
        );
        final second = File(p.join(root.path, 'incoming2'))
          ..writeAsBytesSync([2]);
        await VideoCache().put(
          'https://video.twimg.com/clip.mp4?tag=2',
          second,
          prefs: prefs,
        );

        final firstPath = await VideoCache().localPathFor(
          'https://video.twimg.com/clip.mp4?tag=1',
        );
        final secondPath = await VideoCache().localPathFor(
          'https://video.twimg.com/clip.mp4?tag=2',
        );

        expect(firstPath, isNotNull);
        expect(secondPath, isNotNull);
        expect(
          firstPath,
          isNot(secondPath),
          reason:
              'A basename-only key let the second encode overwrite the first',
        );
        expect(File(firstPath!).readAsBytesSync(), [1]);
        expect(File(secondPath!).readAsBytesSync(), [2]);
      },
    );

    test(
      'Should adopt a legacy basename ledger entry without renaming its file',
      () async {
        final legacy = File(p.join(root.path, 'clip.mp4'))
          ..writeAsBytesSync([7]);
        await File(p.join(root.path, 'video_cache.json')).writeAsString(
          jsonEncode([
            {
              'name': 'clip.mp4',
              'url': 'https://video.twimg.com/clip.mp4?tag=1',
              'size': 1,
              'at': 1,
            },
          ]),
        );

        final path = await VideoCache().localPathFor(
          'https://video.twimg.com/clip.mp4?tag=1',
        );

        expect(
          path,
          legacy.path,
          reason: 'Existing cached bytes must remain usable while the key migrates to the URL hash',
        );
        expect(await legacy.exists(), isTrue);
      },
    );

    test(
      'Should enforce a newly lowered limit on the existing cache',
      () async {
        final first = File(p.join(root.path, 'incoming'))
          ..writeAsBytesSync([1, 2, 3]);
        await VideoCache().put(
          'https://video.twimg.com/a.mp4',
          first,
          prefs: prefs,
        );
        final limited = PrefServiceCache(cache: {optionVideoCacheLimitMb: 0});

        await VideoCache().enforceLimit(limited);

        expect(
          VideoCache().count,
          0,
          reason: 'Startup and preference changes must apply the cap to already cached files',
        );
        expect(
          root.listSync().whereType<File>().where(
            (file) => file.path.endsWith('.mp4'),
          ),
          isEmpty,
        );
      },
    );
  });
}
