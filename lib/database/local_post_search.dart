import 'dart:convert';

import 'package:quax/database/repository.dart';
import 'package:sqflite/sqflite.dart';

/// Local search runs here instead of inside SQLite on purpose: Android ships
/// SQLite without FTS5 (verified on device: "no such module: fts5"), and an
/// index table that silently falls back on the phone is worse than no table.
/// The library is personal-sized, so matching in Dart is fast and, unlike a
/// scan over the stored JSON, it only ever matches what the post says.
final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);

/// A post the user keeps on the device: the stored JSON plus the tables that
/// hold it ([tableSavedTweet] and/or [tableLikedTweet]).
class LocalPost {
  final String id;
  final String? content;
  final Set<String> sources;
  final DateTime? keptAt;

  const LocalPost({required this.id, required this.content, required this.sources, required this.keptAt});
}

/// Every saved and liked post, most recently kept first. These are the rows the
/// Saved tab shows, so a post kept in both places is one entry.
Future<List<LocalPost>> loadLocalPosts(DatabaseExecutor db, {int limit = 2000}) async {
  final posts = <String, LocalPost>{};

  for (final (source, timestamp) in [(tableSavedTweet, 'saved_at'), (tableLikedTweet, 'liked_at')]) {
    final rows =
        await db.query(source, columns: ['id', 'content', timestamp], orderBy: '$timestamp DESC', limit: limit);
    for (final row in rows) {
      final id = row['id'];
      if (id is! String) continue;

      final existing = posts[id];
      posts[id] = LocalPost(
        id: id,
        content: (row['content'] as String?) ?? existing?.content,
        sources: {...?existing?.sources, source},
        keptAt: _newest(existing?.keptAt, _parseTimestamp(row[timestamp])),
      );
    }
  }

  return posts.values.toList()..sort((a, b) => (b.keptAt ?? _epoch).compareTo(a.keptAt ?? _epoch));
}

DateTime? _newest(DateTime? a, DateTime? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a.isAfter(b) ? a : b;
}

DateTime? _parseTimestamp(Object? value) => value is String ? DateTime.tryParse(value) : null;

/// A post ready to be matched: [body] is its lowercased searchable text.
class SearchDoc {
  final LocalPost post;
  final String body;

  const SearchDoc(this.post, this.body);
}

/// The searchable text of a stored post: its own text plus the author's name
/// and handle (as `@handle`, so typing the handle with its @ works), and, for
/// a retweet, the post it carries.
String searchBodyOf(Map<dynamic, dynamic> content) {
  final parts = <String>[
    ..._textsOf(content),
    ..._authorOf(content),
    ..._retweetedOf(content),
  ];
  return parts.where((part) => part.trim().isNotEmpty).join('\n');
}

/// [searchBodyOf] over the stored JSON, lowercased for matching. Unreadable or
/// empty payloads simply have nothing to search.
String searchBodyOfJson(String? json) {
  if (json == null || json.isEmpty) return '';

  try {
    final decoded = jsonDecode(json);
    return decoded is Map ? searchBodyOf(decoded).toLowerCase() : '';
  } on FormatException {
    return '';
  }
}

Iterable<String> _textsOf(Map<dynamic, dynamic> content) sync* {
  for (final key in ['full_text', 'text']) {
    final value = content[key];
    if (value is String) yield value;
  }
}

Iterable<String> _authorOf(Map<dynamic, dynamic> content) sync* {
  final user = content['user'];
  if (user is! Map) return;
  for (final key in ['name', 'screen_name']) {
    final value = user[key];
    if (value is String) yield key == 'screen_name' ? '@$value' : value;
  }
}

Iterable<String> _retweetedOf(Map<dynamic, dynamic> content) sync* {
  final retweeted = content['retweetedStatusWithCard'] ?? content['retweeted_status'];
  if (retweeted is! Map) return;
  yield* _textsOf(retweeted);
  yield* _authorOf(retweeted);
}

class LocalPostMatch {
  final LocalPost post;
  final int score;

  const LocalPostMatch(this.post, this.score);
}

/// Matches [docs] against [query]. Every typed word has to appear somewhere,
/// a word that starts a word in the post scores above one buried inside
/// another, and equal posts are ordered newest first.
List<LocalPostMatch> rankLocalPosts(Iterable<SearchDoc> docs, String query, {int limit = 60}) {
  final terms = query.toLowerCase().split(RegExp(r'\s+')).where((term) => term.isNotEmpty);
  if (terms.isEmpty) return const [];

  final matches = <LocalPostMatch>[];
  for (final doc in docs) {
    if (doc.body.isEmpty) continue;

    var score = 0;
    var matchedEveryTerm = true;
    for (final term in terms) {
      final at = doc.body.indexOf(term);
      if (at < 0) {
        matchedEveryTerm = false;
        break;
      }
      score += _startsWord(doc.body, at) ? 3 : 1;
    }

    if (matchedEveryTerm) matches.add(LocalPostMatch(doc.post, score));
  }

  matches.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    return (b.post.keptAt ?? _epoch).compareTo(a.post.keptAt ?? _epoch);
  });

  return matches.length > limit ? matches.sublist(0, limit) : matches;
}

bool _startsWord(String body, int index) => index == 0 || !_isWordChar(body.codeUnitAt(index - 1));

bool _isWordChar(int codeUnit) {
  final isDigit = codeUnit >= 0x30 && codeUnit <= 0x39;
  final isUpper = codeUnit >= 0x41 && codeUnit <= 0x5A;
  final isLower = codeUnit >= 0x61 && codeUnit <= 0x7A;
  return isDigit || isUpper || isLower || codeUnit == 0x5F;
}
