import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/cached/cached_tweets_model.dart';
import 'package:quax/client/client.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/utils/tweet_freshness_index.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  Directory? tempDbDir;
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // A private databases path: the test files run in parallel isolates, and
    // repository_test drives the shared default path.
    final dir = await Directory.systemTemp.createTemp('quax_cached_test');
    tempDbDir = dir;
    await databaseFactory.setDatabasesPath(dir.path);
    await deleteDatabase(databaseName);
    await Repository().migrate();
    // TweetWithCard.tombstone resolves a localized message.
    await L10n.load(const Locale('en'));
  });

  setUp(() async {
    // The tests share one database: start each test from an empty archive.
    final model = CachedTweetModel();
    await model.clear(CachedFeedSource.foryou);
    await model.clear(CachedFeedSource.following);
  });

  TweetChain chainOf(String id, {String text = 'hello'}) => TweetChain(
    id: id,
    isPinned: false,
    tweets: [TweetWithCard.tombstone({})..idStr = id],
  );

  group('CachedTweetModel.archive()', () {
    test(
      'Should keep one row per id, with the freshest copy winning',
      () async {
        final model = CachedTweetModel();
        await model.archive([chainOf('t1')], source: CachedFeedSource.foryou);
        await model.archive([
          TweetChain(
            id: 't1',
            isPinned: false,
            tweets: [chainOf('t1').tweets.first],
          ),
        ], source: CachedFeedSource.foryou);

        final counts = await model.counts();
        expect(
          counts['foryou'],
          1,
          reason:
              'The same tweet surfaces twice in a ranked feed; archiving '
              'must upsert by id instead of duplicating the row',
        );
      },
    );

    test('Should keep the sources apart', () async {
      final model = CachedTweetModel();
      await model.archive([chainOf('t2')], source: CachedFeedSource.following);

      final foryou = await model.loadPage(
        source: CachedFeedSource.foryou,
        cursor: null,
      );
      final following = await model.loadPage(
        source: CachedFeedSource.following,
        cursor: null,
      );

      expect(
        foryou.chains.any((chain) => chain.id == 't2'),
        isFalse,
        reason: 'A Following post must not appear under the For You tab',
      );
      expect(
        following.chains.map((chain) => chain.id),
        contains('t2'),
        reason: 'The sub-tabs mirror the home tabs, so the source decides',
      );
    });

    test(
      'Should round-trip the chain content through the stored JSON',
      () async {
        final model = CachedTweetModel();
        await model.archive([
          chainOf('t3', text: 'round trip'),
        ], source: CachedFeedSource.foryou);

        final page = await model.loadPage(
          source: CachedFeedSource.foryou,
          cursor: null,
        );

        final restored = page.chains.first;
        expect(
          restored.id,
          't3',
          reason: 'The Offline tab renders the same chains the home saw',
        );
        expect(
          restored.tweets,
          isNotEmpty,
          reason: 'A chain without its tweets cannot be rendered',
        );
        expect(
          jsonEncode(restored.toJson()),
          isNotEmpty,
          reason: 'The stored JSON must survive a decode/encode round trip',
        );
      },
    );
  });

  group('CachedTweetModel.loadPage()', () {
    test('Should page in insertion order with an offset cursor', () async {
      final model = CachedTweetModel();
      await model.archive([
        for (var i = 0; i < 25; i++) chainOf('page$i'),
      ], source: CachedFeedSource.following);

      final first = await model.loadPage(
        source: CachedFeedSource.following,
        cursor: null,
      );
      expect(
        first.chains.length,
        CachedTweetModel.pageSize,
        reason: 'A full page comes back while more rows remain',
      );
      expect(
        first.nextCursor,
        '${CachedTweetModel.pageSize}',
        reason: 'The cursor is the row offset the next page reads from',
      );

      final second = await model.loadPage(
        source: CachedFeedSource.following,
        cursor: first.nextCursor,
      );
      expect(
        second.chains.first.id,
        isNot(first.chains.first.id),
        reason: 'The second page must not repeat the first one',
      );

      final last = await model.loadPage(
        source: CachedFeedSource.following,
        cursor: '30',
      );
      expect(
        last.chains,
        isEmpty,
        reason: 'Past the end there is nothing left',
      );
      expect(
        last.nextCursor,
        isNull,
        reason: 'A null cursor ends the pagination',
      );
    });

    test(
      'Should end the pagination when the archive is exactly one page',
      () async {
        final model = CachedTweetModel();
        await model.archive([
          chainOf('single'),
        ], source: CachedFeedSource.following);

        final page = await model.loadPage(
          source: CachedFeedSource.following,
          cursor: null,
        );
        expect(
          page.nextCursor,
          isNull,
          reason: 'An exactly-one-page archive has no next page',
        );
      },
    );

    test('Should clear one source without touching the other', () async {
      final model = CachedTweetModel();
      await model.archive([
        chainOf('clear-me'),
      ], source: CachedFeedSource.foryou);
      await model.archive([
        chainOf('keep-me'),
      ], source: CachedFeedSource.following);

      await model.clear(CachedFeedSource.foryou);

      final foryou = await model.loadPage(
        source: CachedFeedSource.foryou,
        cursor: null,
      );
      final following = await model.loadPage(
        source: CachedFeedSource.following,
        cursor: null,
      );
      expect(
        foryou.chains,
        isEmpty,
        reason: 'The Clear button removes exactly the active tab',
      );
      expect(
        following.chains.map((chain) => chain.id),
        contains('keep-me'),
        reason: 'The sibling archive must survive the clear',
      );
    });
  });

  group('CachedTweetModel.splitByFreshness()', () {
    test('Should split the chains by the freshness baseline', () async {
      SharedPreferences.setMockInitialValues({});
      final index = TweetFreshnessIndex();
      await index.resetForTests();
      await index.load();

      // Session 1: the home loads a tweet; the flush writes the snapshot at
      // the session boundary (paused → flush).
      index.note(['seen-before']);
      await index.flush();

      // Session 2: a fresh launch reads the stored snapshot into the baseline.
      await index.resetForTests();
      await index.load();

      final chains = [chainOf('seen-before'), chainOf('brand-new')];
      final split = CachedTweetModel.splitByFreshness(chains);

      expect(
        split.fresh.map((chain) => chain.id),
        contains('brand-new'),
        reason: 'A tweet never loaded before is exactly what the home shows',
      );
      expect(
        split.fresh.map((chain) => chain.id),
        isNot(contains('seen-before')),
        reason:
            'A tweet from an earlier session goes to the archive, not the home',
      );
      expect(
        split.cached.map((chain) => chain.id),
        contains('seen-before'),
        reason: 'The split hands the archived tweet to the archiver',
      );
      expect(
        index.isCached('seen-before'),
        isTrue,
        reason: 'isCached is the same predicate the filter uses',
      );
      expect(
        index.isNew('brand-new'),
        isTrue,
        reason: 'The New/Old label keeps working alongside the filter',
      );
    });
  });

  tearDownAll(() async {
    try {
      tempDbDir?.deleteSync(recursive: true);
    } catch (_) {
      // The temp database directory is best-effort cleanup.
    }
  });
}
