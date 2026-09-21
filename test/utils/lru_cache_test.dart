import 'package:flutter_test/flutter_test.dart';
import 'package:quax/utils/lru_cache.dart';

void main() {
  group('LruCache', () {
    test('Should return what was stored', () {
      final cache = LruCache<String, int>(4)..set('a', 1);

      expect(cache.get('a'), 1,
          reason: 'The cache exists so list items do not re-parse their content, so a stored value '
              'has to come back');
    });

    test('Should report a miss for an unknown key', () {
      final cache = LruCache<String, int>(4);

      expect(cache.get('nope'), isNull,
          reason: 'A miss must be distinguishable from a stored value, otherwise the caller cannot '
              'decide to decode again');
    });

    test('Should drop the oldest entry once it is full', () {
      final cache = LruCache<String, int>(2)..set('first', 1)..set('second', 2);

      cache.set('third', 3);

      expect(cache.get('first'), isNull,
          reason: 'Holding every parsed tweet forever would grow without bound, so the least '
              'recently used entry has to leave when the capacity is reached');
      expect(cache.get('third'), 3,
          reason: 'The newest entry is the one just written and must survive');
    });

    test('Should treat a read as a use', () {
      final cache = LruCache<String, int>(2)..set('first', 1)..set('second', 2);

      cache.get('first');
      cache.set('third', 3);

      expect(cache.get('second'), isNull,
          reason: 'The visible item is read on every rebuild; evicting it while it is on screen '
              'would re-parse the very item the cache was meant to keep');
      expect(cache.get('first'), 1,
          reason: 'Reading an entry makes it the most recently used, so it stays over the one that '
              'was not touched');
    });

    test('Should replace the value of an existing key without growing', () {
      final cache = LruCache<String, int>(2)..set('a', 1);

      cache.set('a', 2);

      expect(cache.length, 1,
          reason: 'Re-storing the same key is a refresh, not a second entry');
      expect(cache.get('a'), 2,
          reason: 'The freshest value should win');
    });
  });
}
