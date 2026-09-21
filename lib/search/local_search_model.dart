import 'package:flutter_triple/flutter_triple.dart';
import 'package:logging/logging.dart';
import 'package:pref/pref.dart';
import 'package:quax/database/local_post_search.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/library/library_model.dart';
import 'package:quax/utils/lru_cache.dart';

/// A result of the offline search: a post from the local database, or a media
/// file sitting in the hidden library.
sealed class LocalSearchHit {
  const LocalSearchHit();
}

class LocalPostHit extends LocalSearchHit {
  final LocalPost post;

  const LocalPostHit(this.post);
}

class LocalMediaHit extends LocalSearchHit {
  final LibraryEntry entry;

  const LocalMediaHit(this.entry);
}

/// Searches the device only: saved and liked posts are matched in Dart, the
/// downloaded media by file name. The query never reaches X.
class LocalSearchModel extends Store<List<LocalSearchHit>> {
  static final log = Logger('LocalSearchModel');

  final BasePrefService prefs;
  late final LibraryModel _library = LibraryModel(prefs);
  final LruCache<String, String> _bodies = LruCache<String, String>(300);
  String _query = '';

  LocalSearchModel(this.prefs) : super(const []);

  String get query => _query;

  Future<void> search(String query) async {
    _query = query;
    final trimmed = query.trim();

    if (trimmed.isEmpty) {
      update(const [], force: true);
      return;
    }

    await execute(() async {
      // The shared connection: search runs on every debounced keystroke, and a
      // read-only connection per query would pile up open handles.
      final database = await Repository.writable();
      final posts = await loadLocalPosts(database);
      final matches = rankLocalPosts([for (final post in posts) SearchDoc(post, _bodyFor(post))], trimmed);
      final files = await _library.searchByName(trimmed);

      // Another keystroke landed while the query ran: drop this answer instead
      // of flashing results for a query the user already moved past.
      if (_query != query) return state;

      return <LocalSearchHit>[
        for (final match in matches) LocalPostHit(match.post),
        for (final file in files) LocalMediaHit(file),
      ];
    });
  }

  /// Decoding a stored post is the expensive part of a search, and the list is
  /// re-scanned on every keystroke: keep the bodies of the rows that did not
  /// change since the last query.
  String _bodyFor(LocalPost post) {
    final key = '${post.id}#${post.content?.hashCode}';
    final cached = _bodies.get(key);
    if (cached != null) return cached;

    final body = searchBodyOfJson(post.content);
    _bodies.set(key, body);
    return body;
  }

  Future<String?> thumbnailFor(LibraryEntry entry) => _library.thumbnailFor(entry);

  Future<bool> openExternally(String path) => _library.openExternally(path);
}
