import 'package:flutter_test/flutter_test.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/saved/saved_tweet_folder_model.dart';
import 'package:quax/saved/saved_tweet_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    await deleteDatabase(databaseName);
  });

  Future<Set<Object?>> tableNames(Database db) async {
    final rows = await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'");
    return rows.map((row) => row['name']).toSet();
  }

  group('Repository.migrate()', () {
    test('Should create every table the app reads on a fresh install', () async {
      await Repository().migrate();

      final db = await openDatabase(databaseName, readOnly: true);
      final tables = await tableNames(db);
      await db.close();

      for (final table in [
        tableSubscription,
        tableSubscriptionGroup,
        tableSubscriptionGroupMember,
        tableSavedTweet,
        tableSavedTweetFolder,
        tableLikedTweet,
        tableFeedGroupChunk,
        tableFeedGroupCursor,
        tableAccounts,
      ]) {
        expect(tables, contains(table),
            reason: '"$table" is queried by a model, so a fresh install without it would crash '
                'the first time that screen opens');
      }
    });

    test('Should end at the newest schema version', () async {
      await Repository().migrate();

      final db = await Repository.readOnly();
      final version = await db.getVersion();
      await db.close();

      expect(version, 27,
          reason: 'The version has to match the last migration step, otherwise the next app launch '
              'replays steps on top of a schema that already has them and the ALTERs fail');
    });

    test('Should add the columns of the saved, liked and account features', () async {
      await Repository().migrate();

      final db = await Repository.readOnly();
      final savedColumns = (await db.rawQuery('PRAGMA table_info($tableSavedTweet)'))
          .map((row) => row['name'])
          .toSet();
      final accountColumns = (await db.rawQuery('PRAGMA table_info($tableAccounts)'))
          .map((row) => row['name'])
          .toSet();
      await db.close();

      expect(savedColumns, contains('folder_id'),
          reason: 'The saved posts screen files posts into folders through this column, so it has '
              'to exist even on a database created before folders were introduced');
      expect(accountColumns, contains('is_active'),
          reason: 'The account sheet switches accounts through this column');
    });

    test('Should carry a legacy following list into the subscription table', () async {
      final legacy = await openDatabase(databaseName, version: 5, onCreate: (db, version) async {
        await db.execute(
            'CREATE TABLE following (id VARCHAR PRIMARY KEY, screen_name VARCHAR, name VARCHAR, profile_image_url_https VARCHAR, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)');
        await db.execute(
            'CREATE TABLE following_group (id INTEGER PRIMARY KEY, name VARCHAR NOT NULL, icon VARCHAR NOT NULL, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)');
        await db.execute('CREATE TABLE following_group_profile (group_id INTEGER, profile_id VARCHAR)');
      });
      await legacy.insert('following', {'id': 'u1', 'screen_name': 'dogs', 'name': 'Dogs'});
      await legacy.close();

      await Repository().migrate();

      final db = await Repository.readOnly();
      final rows = await db.query(tableSubscription, where: 'id = ?', whereArgs: ['u1']);
      await db.close();

      expect(rows, hasLength(1),
          reason: 'Users upgrading from the old "following" schema should not lose the people they '
              'followed, the migration renames the table instead of recreating it');
      expect(rows.single['screen_name'], 'dogs',
          reason: 'The row should arrive with its values, not only its id');
    });
  });

  group('Saved posts storage', () {
    setUp(() async {
      await deleteDatabase(databaseName);
      await Repository().migrate();
    });

    test('Should save, file and delete a post', () async {
      final model = SavedTweetModel();

      await model.saveTweet('t1', 'u1', {'id_str': 't1'});
      await model.listSavedTweets();
      expect(model.isSaved('t1'), isTrue,
          reason: 'The bookmark button reads this list to draw itself filled, so the written row '
              'has to come back from the database');

      await model.setFolder('t1', 'f1');
      await model.listSavedTweets();
      expect(model.folderOf('t1'), 'f1',
          reason: 'Filing a post should survive the reload, otherwise the folder chip filters it '
              'away on the next visit');

      await model.deleteSavedTweet('t1');
      await model.listSavedTweets();
      expect(model.isSaved('t1'), isFalse,
          reason: 'Unsaving should remove both the in-memory entry and the row, or the bookmark '
              'button still reads as filled after a restart');
    });

    test('Should list the most recently saved post first', () async {
      final model = SavedTweetModel();

      await model.saveTweet('old', null, {});
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await model.saveTweet('new', null, {});
      await model.listSavedTweets();

      expect(model.state.map((tweet) => tweet.id), ['new', 'old'],
          reason: 'Saved posts are shown newest-first like a feed, so the order has to come from '
              'the database and not from the insertion order of a map');
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('Should move a folder\'s posts back to unfiled when the folder is deleted', () async {
      final folders = SavedTweetFolderModel();
      final saved = SavedTweetModel();
      final folder = await folders.createFolder('Dogs');

      await saved.saveTweet('t1', 'u1', {}, folderId: folder.id);
      await saved.listSavedTweets();
      expect(saved.folderOf('t1'), folder.id,
          reason: 'The picking sheet writes the folder id, so the post should start inside it');

      await folders.deleteFolder(folder.id);
      await saved.listSavedTweets();

      expect(saved.folderOf('t1'), isNull,
          reason: 'Deleting a folder must not delete the posts it holds, they should fall back to '
              'Unfiled instead of disappearing with the folder filter');
    });

    test('Should keep the folders in creation order when listing them', () async {
      final folders = SavedTweetFolderModel();

      await folders.createFolder('First');
      await folders.createFolder('Second');
      await folders.listFolders();

      expect(folders.state.map((folder) => folder.name), ['First', 'Second'],
          reason: 'The Saved strip shows folders in this order, so a new folder should land after '
              'the ones created before it');
    });
  });
}
