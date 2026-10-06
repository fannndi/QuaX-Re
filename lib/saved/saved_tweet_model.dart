import 'dart:convert';

import 'package:flutter_triple/flutter_triple.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:logging/logging.dart';

class SavedTweetModel extends Store<List<SavedTweet>> {
  static final log = Logger('SavedTweetModel');

  SavedTweetModel() : super([]);

  /// Id → folder for the list currently held, rebuilt only when the list itself
  /// is replaced. Both lookups below run for every visible card on every rebuild
  /// of the post footer, so scanning the whole list each time costs what the
  /// reader has saved rather than what is on screen — thousands of comparisons
  /// per scroll frame once a library grows.
  List<SavedTweet>? _indexedFrom;
  Map<String, String?> _byId = const {};

  Map<String, String?> _index() {
    final current = state;
    if (!identical(_indexedFrom, current)) {
      _indexedFrom = current;
      _byId = {for (final saved in current) saved.id: saved.folderId};
    }
    return _byId;
  }

  bool isSaved(String id) => _index().containsKey(id);

  String? folderOf(String id) => _index()[id];

  Future<void> setFolder(String id, String? folderId) async {
    var database = await Repository.writable();

    await database.update(tableSavedTweet, {'folder_id': folderId}, where: 'id = ?', whereArgs: [id]);

    update(state.map((e) => e.id == id ? e.copyWith(folderId: folderId) : e).toList(), force: true);
  }

  Future<void> deleteSavedTweet(String id) async {
    var database = await Repository.writable();

    await database.delete(tableSavedTweet, where: 'id = ?', whereArgs: [id]);
    // A new list, not a mutation of the one in hand: the memo above keys off the
    // list identity, and a listener comparing the old and new state sees the
    // same object either way.
    update(state.where((e) => e.id != id).toList(), force: true);
  }

  Future<void> listSavedTweets() async {
    log.info('Listing saved tweets');

    await execute(() async {
      final rows = await Repository.read((db) => db.query(tableSavedTweet, orderBy: 'saved_at DESC'));
      return rows.map((e) => SavedTweet.fromMap(e)).toList();
    });
  }

  /// Reloads without entering the loading state, so the current list stays visible
  /// until the fresh data is ready (used for pull-to-refresh).
  Future<void> refreshSavedTweets() async {
    log.info('Refreshing saved tweets');

    final rows = await Repository.read((db) => db.query(tableSavedTweet, orderBy: 'saved_at DESC'));
    update(rows.map((e) => SavedTweet.fromMap(e)).toList(), force: true);
  }

  Future<void> saveTweet(String id, String? user, Map<String, dynamic> content, {String? folderId}) async {
    log.info('Saving tweet with the ID $id');

    await execute(() async {
      var database = await Repository.writable();

      var encodedContent = jsonEncode(content);

      await database.insert(
          tableSavedTweet, {'id': id, 'user_id': user, 'content': encodedContent, 'folder_id': folderId});

      return [...state, SavedTweet(id: id, user: user, content: encodedContent, folderId: folderId)];
    });
  }
}
