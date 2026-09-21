import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/database/local_post_search.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/saved/liked_tweet_model.dart';
import 'package:quax/saved/saved_tweet_folder_model.dart';
import 'package:quax/saved/saved_tweet_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A stored post the way `TweetWithCard.toJson()` writes it: the search reads
/// `full_text` and the nested user.
Map<String, dynamic> storedTweet(String id, String text,
    {String name = 'Alice', String handle = 'alice'}) {
  return {
    'id_str': id,
    'full_text': text,
    'user': {'id_str': 'u1', 'name': name, 'screen_name': handle},
  };
}

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

  /// The ids the local search would show for [query], best match first.
  Future<List<String>> search(String query) async {
    final db = await Repository.writable();
    final docs = [
      for (final post in await loadLocalPosts(db)) SearchDoc(post, searchBodyOfJson(post.content)),
    ];
    return rankLocalPosts(docs, query).map((match) => match.post.id).toList();
  }

  group('Repository.migrate()', () {
    setUp(() async {
      await deleteDatabase(databaseName);
    });

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

      expect(version, 28,
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

    test('Should drop the full-text table an earlier build created', () async {
      final legacy = await openDatabase(databaseName, version: 27, onCreate: (db, version) async {
        await db.execute('CREATE TABLE tweet_search (tweet_id VARCHAR, source VARCHAR, body VARCHAR)');
        await db.execute('CREATE TABLE feed_group_chunk (cursor_id INTEGER NOT NULL, hash VARCHAR NOT NULL, '
            'cursor_top VARCHAR, cursor_bottom VARCHAR, response VARCHAR, '
            'created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)');
        await db.execute('CREATE TABLE feed_group_cursor (id INTEGER PRIMARY KEY, '
            'created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)');
      });
      await legacy.close();

      await Repository().migrate();

      final db = await Repository.readOnly();
      final tables = await tableNames(db);
      await db.close();

      expect(tables, isNot(contains('tweet_search')),
          reason: 'Search ignores that table now, and leaving it behind on upgraded installs would '
              'keep a stale copy of every saved post around');
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

  group('Local search matching', () {
    SearchDoc doc(String id, String body, {DateTime? keptAt}) => SearchDoc(
        LocalPost(
            id: id,
            content: null,
            sources: const {tableSavedTweet},
            keptAt: keptAt ?? DateTime.fromMillisecondsSinceEpoch(0)),
        body.toLowerCase());

    test('Should require every typed word', () {
      final docs = [doc('a', 'a post about sandwiches'), doc('b', 'a post about sandwiches and bread')];

      expect(rankLocalPosts(docs, 'sandwich bread').map((match) => match.post.id), ['b'],
          reason: 'Typing more words has to narrow the results down, otherwise the tab shows '
              'everything the first word matched');
    });

    test('Should rank a word start above a word buried inside another', () {
      final docs = [doc('buried', 'a thousand reasons'), doc('start', 'a sandwich')];

      expect(rankLocalPosts(docs, 'sand').map((match) => match.post.id), ['start', 'buried'],
          reason: 'The posts the user means should come first, a substring hit inside another '
              'word is a weaker match');
    });

    test('Should order equal matches newest first', () {
      final docs = [
        doc('old', 'sandwich', keptAt: DateTime(2024)),
        doc('new', 'sandwich', keptAt: DateTime(2025)),
      ];

      expect(rankLocalPosts(docs, 'sandwich').map((match) => match.post.id), ['new', 'old'],
          reason: 'The Saved tab is chronological, so equally good matches should read the same way');
    });

    test('Should treat punctuation in the query as plain characters', () {
      final docs = [doc('a', '50% off everything')];

      expect(rankLocalPosts(docs, '50%').map((match) => match.post.id), ['a'],
          reason: 'Nothing the user types should be able to turn into a search operator');
    });

    test('Should index the author and the retweeted post next to the text', () {
      final body = searchBodyOf({
        'full_text': 'look at this',
        'user': {'name': 'Alice', 'screen_name': 'alice'},
        'retweetedStatusWithCard': {
          'full_text': 'the original post',
          'user': {'name': 'Bob', 'screen_name': 'bob'},
        },
      });

      expect(body, contains('@alice'),
          reason: 'Typing a handle with its @ should find the author\'s posts even when the text '
              'never mentions them');
      expect(body, contains('Bob'),
          reason: 'A retweet has to stay findable through the post it carries, on some responses '
              'its own full_text is only "RT @bob: ..."');
    });
  });

  group('Local search', () {
    // Emptying the tables beats deleting the database file: the models hold on
    // to cached connections, and a reopened database can keep pointing at a
    // file that was only unlinked, not removed.
    setUp(() async {
      await Repository().migrate();
      final db = await Repository.writable();
      await db.delete(tableSavedTweet);
      await db.delete(tableLikedTweet);
    });

    test('Should find a saved post by a word in its text', () async {
      await SavedTweetModel().saveTweet('t1', 'u1', storedTweet('t1', 'a post about sandwiches'));

      expect(await search('sandwiches'), ['t1'],
          reason: 'Saving a post has to make it findable, or the Local tab stays empty for '
              'everything the user kept');
      expect(await search('SANDWICHES'), ['t1'],
          reason: 'The box is not case-sensitive, users type what they remember');
    });

    test('Should find a post by its author', () async {
      await SavedTweetModel().saveTweet(
          't2', 'u9', storedTweet('t2', 'nothing to see', name: 'Bob Burger', handle: 'bobburger'));

      expect(await search('@bobburger'), ['t2'],
          reason: 'The Local tab is the only way to find a saved post whose text is not '
              'memorable, the handle has to be searchable');
    });

    test('Should match while the word is still being typed', () async {
      await SavedTweetModel().saveTweet('t3', null, storedTweet('t3', 'a large sandwich'));

      expect(await search('sandw'), ['t3'],
          reason: 'Search runs on a debounce as the user types, so partial words have to match or '
              'results only appear once the whole word is there');
    });

    test('Should not match the storage format of a post', () async {
      await SavedTweetModel().saveTweet('t4', null, storedTweet('t4', 'a sandwich'));

      expect(await search('full_text'), isEmpty,
          reason: 'Only what the post says is searchable; matching the raw JSON would return every '
              'post for a word like "user"');
    });

    test('Should drop a post as soon as it is unsaved', () async {
      final saved = SavedTweetModel();
      await saved.saveTweet('t5', null, storedTweet('t5', 'a sandwich'));
      await saved.deleteSavedTweet('t5');

      expect(await search('sandwich'), isEmpty,
          reason: 'The Local tab reads the same rows, so an unsaved post must not come back');
    });

    test('Should list a post kept in both places once, with both sources', () async {
      final content = storedTweet('t6', 'sandwich everywhere');
      await SavedTweetModel().saveTweet('t6', 'u1', content);
      await LikedTweetModel().likeTweet('t6', 'u1', content);

      final db = await Repository.writable();
      final posts = await loadLocalPosts(db);

      expect(posts, hasLength(1),
          reason: 'The Local tab shows one card per post; being saved and liked is one post, not '
              'two results');
      expect(posts.single.sources, containsAll([tableSavedTweet, tableLikedTweet]),
          reason: 'Both keeping places have to be recorded, the card says how the post was kept');
    });

    test('Should drop a post as soon as it is unliked', () async {
      final liked = LikedTweetModel();
      await liked.likeTweet('t7', null, storedTweet('t7', 'a sandwich'));
      await liked.unlikeTweet('t7');

      expect(await search('sandwich'), isEmpty,
          reason: 'Unliking a post removes the only local copy left, it must not keep showing');
    });

    test('Should skip a post whose stored payload cannot be read', () async {
      final db = await Repository.writable();
      await db.insert(tableSavedTweet, {'id': 'broken', 'content': 'this is not json'});
      await SavedTweetModel().saveTweet('t8', null, storedTweet('t8', 'a sandwich'));

      expect(await search('sandwich'), ['t8'],
          reason: 'One corrupt row must not break the whole tab');
    });
  });

  group('Active account', () {
    // Clearing the table beats deleting the database file: the factories hold
    // on to cached connections, and a reopened database can keep pointing at a
    // file that was only unlinked, not removed.
    setUp(() async {
      await Repository().migrate();
      final db = await Repository.writable();
      await db.delete(tableAccounts);
      activeAccount.value = null;
      accountsRevision.value = 0;
    });

    Future<void> addAccount(String id, String handle) async {
      final db = await Repository.writable();
      await db.insert(tableAccounts, {'id': id, 'auth_header': '{}', 'screen_name': handle});
    }

    test('Should remember the chosen account in memory', () async {
      await addAccount('a1', 'first');
      await addAccount('a2', 'second');

      await setActiveAccount('a2');

      expect(activeAccount.value?.id, 'a2',
          reason: 'The home app bar shows the handle and the feeds key their scroll memory on '
              'this value, so a switch has to publish it without a database read');
      expect(activeAccount.value?.handle, 'second',
          reason: 'The account button draws the initial from the handle');
      expect((await getActiveAccount())?.id, 'a2',
          reason: 'The next launch reads the active flag from the database, it has to agree');
    });

    test('Should not report a switch when the account is already the active one', () async {
      await addAccount('a1', 'first');
      await setActiveAccount('a1');
      final revision = accountsRevision.value;

      await setActiveAccount('a1');

      expect(accountsRevision.value, revision,
          reason: 'Picking the account that is already active must not drop the feeds the reader '
              'is looking at');
    });

    test('Should promote the first account when none is flagged', () async {
      await addAccount('a1', 'first');
      await addAccount('a2', 'second');
      await setActiveAccount('a2');
      final db = await Repository.writable();
      await db.update(tableAccounts, {'is_active': 0});

      await promoteFirstAccountIfNoneActive();

      expect(activeAccount.value?.id, 'a1',
          reason: 'Deleting the active account leaves no flag behind; the app then has to adopt '
              'another login instead of keeping a pointer to the deleted one');
    });

    test('Should forget the account when the last one is deleted', () async {
      await addAccount('a1', 'first');
      await setActiveAccount('a1');
      final db = await Repository.writable();
      await db.delete(tableAccounts);

      await promoteFirstAccountIfNoneActive();

      expect(activeAccount.value, isNull,
          reason: 'With no accounts left nothing may be shown as the active login');
    });
  });
}
