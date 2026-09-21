import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/client.dart';
import 'package:quax/group/feed_cache.dart';

void main() {
  Map<String, Object?> chainJson(String id, String createdAt) => {
        'id': id,
        'tweets': [
          {'id_str': '${id}_tweet', 'created_at': createdAt},
        ],
        'isPinned': false,
      };

  Map<String, Object?> storedChunk(List<Map<String, Object?>> chains) =>
      {'response': jsonEncode(chains), 'hash': 'h', 'created_at': '2026-01-01 00:00:00'};

  group('chainsFromStoredChunks()', () {
    test('Should read every chain of every stored chunk in order', () {
      final chains = chainsFromStoredChunks([
        storedChunk([chainJson('c1', '2026-01-01T10:00:00.000Z')]),
        storedChunk([
          chainJson('c2', '2026-01-01T11:00:00.000Z'),
          chainJson('c3', '2026-01-01T12:00:00.000Z'),
        ]),
      ]);

      expect(chains.map((chain) => chain.id), ['c1', 'c2', 'c3'],
          reason: 'The DB rows are the source of the offline feed, so a chunk that silently drops '
              'chains would leave holes in the timeline that was just read back');
    });

    test('Should keep the tweets of each chain, not only its id', () {
      final chains = chainsFromStoredChunks([
        storedChunk([chainJson('c1', '2026-01-01T10:00:00.000Z')]),
      ]);

      expect(chains.single.tweets.single.idStr, 'c1_tweet',
          reason: 'The response is re-parsed from JSON, so the embedded tweet should survive with '
              'the fields the card needs to render');
    });
  });

  group('sortChainsNewestFirst()', () {
    TweetChain chain(String id, DateTime? createdAt) {
      final tweet = TweetWithCard()..createdAt = createdAt;
      return TweetChain(id: id, tweets: [tweet], isPinned: false);
    }

    test('Should put the most recent chain first', () {
      final sorted = sortChainsNewestFirst([
        chain('old', DateTime(2026, 1, 1)),
        chain('new', DateTime(2026, 1, 3)),
        chain('middle', DateTime(2026, 1, 2)),
      ]);

      expect(sorted.map((c) => c.id), ['new', 'middle', 'old'],
          reason: 'Chunks are read oldest-first from the DB, so this sort is what makes the joined '
              'offline feed read like a timeline instead of a reversed one');
    });

    test('Should leave chains without a creation date where they are', () {
      final sorted = sortChainsNewestFirst([
        chain('undated', null),
        chain('dated', DateTime(2026, 1, 1)),
      ]);

      expect(sorted.map((c) => c.id), ['undated', 'dated'],
          reason: 'A chain missing created_at cannot be compared to anything, and dropping it would '
              'hide a cached tweet forever');
    });
  });
}
