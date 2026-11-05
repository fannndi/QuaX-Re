import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/likes/liked_tweet_model.dart';
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
    setUp(() async {
      await deleteDatabase(databaseName);
    });

    test('Should create every schema table on a fresh install', () async {
      await Repository().migrate();

      final db = await openDatabase(databaseName, readOnly: true);
      final tables = await tableNames(db);
      await db.close();

      for (final table in [
        tableSubscription,
        tableSubscriptionGroup,
        tableSubscriptionGroupMember,
        tableLikedTweet,
        tableAccounts,
      ]) {
        expect(tables, contains(table),
            reason: '"$table" is created by a migration, so a fresh install must match the '
                'schema an upgraded install ends on');
      }

      for (final table in [tableSavedTweet, tableSavedTweetFolder]) {
        expect(tables, contains(table),
            reason: '"$table" is no longer read by the app, but it stays in the schema so an '
                'upgraded install never drops the posts a previous build saved');
      }

      for (final table in [tableFeedGroupChunk, tableFeedGroupCursor]) {
        expect(tables, isNot(contains(table)),
            reason: 'The chunk cache belonged to the group feeds, which are gone; carrying the '
                'tables into a fresh install would invite code to write into them again');
      }
    });

    test('Should end at the newest schema version', () async {
      await Repository().migrate();

      final db = await Repository.readOnly();
      final version = await db.getVersion();
      await db.close();

      expect(version, 31,
          reason: 'The version has to match the last migration step, otherwise the next app launch '
              'replays steps on top of a schema that already has them and the ALTERs fail');
    });

    test('Should index the columns the hot lookups filter on', () async {
      await Repository().migrate();

      final db = await Repository.readOnly();
      final indexes = (await db.rawQuery(
              "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%'"))
          .map((row) => row['name'] as String)
          .toSet();
      await db.close();

      expect(indexes, contains('idx_subscription_group_member_profile_id'),
          reason: 'Migration 31 keeps this index on the retained group tables; a fresh install '
              'missing it would differ from an upgraded one');
      expect(indexes, contains('idx_accounts_is_active'),
          reason: 'setActiveAccount clears the flag with `WHERE is_active = 1` on every account '
              'switch');
      expect(indexes, contains('idx_subscription_screen_name'),
          reason: 'Migration 31 keeps this index on the retained subscription table; a fresh '
              'install missing it would differ from an upgraded one');
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

    test('Should drop the tables an earlier build created that nothing reads anymore', () async {
      // A real install at 27 carries every table migrations 2..27 created, not
      // only the ones this test cares about — migration 29 indexes saved_tweet
      // and liked_tweet, which would be missing from a skeleton schema.
      final legacy = await openDatabase(databaseName, version: 27, onCreate: (db, version) async {
        await db.execute('CREATE TABLE accounts (id TEXT PRIMARY KEY, auth_header VARCHAR, '
            'screen_name VARCHAR DEFAULT NULL, last_not_found_at TEXT DEFAULT NULL, '
            'consecutive_not_found INTEGER DEFAULT 0, is_active INTEGER DEFAULT 0)');
        await db.execute('CREATE TABLE tweet_search (tweet_id VARCHAR, source VARCHAR, body VARCHAR)');
        await db.execute('CREATE TABLE feed_group_chunk (cursor_id INTEGER NOT NULL, hash VARCHAR NOT NULL, '
            'cursor_top VARCHAR, cursor_bottom VARCHAR, response VARCHAR, '
            'created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)');
        await db.execute('CREATE TABLE feed_group_cursor (id INTEGER PRIMARY KEY, '
            'created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)');
        await db.execute('CREATE TABLE saved_tweet (id VARCHAR PRIMARY KEY, content TEXT NOT NULL, '
            'saved_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)');
        await db.execute('CREATE TABLE liked_tweet (id VARCHAR PRIMARY KEY, content TEXT NOT NULL, '
            'user_id VARCHAR DEFAULT NULL, liked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)');
      });
      await legacy.close();

      await Repository().migrate();

      final db = await Repository.readOnly();
      final tables = await tableNames(db);
      await db.close();

      expect(tables, isNot(contains('tweet_search')),
          reason: 'Search ignores that table now, and leaving it behind on upgraded installs would '
              'keep a stale copy of every saved post around');
      expect(tables, isNot(contains('feed_group_chunk')),
          reason: 'Nothing writes or reads the chunk cache since the group feeds went away, and '
              'carrying it over would only give the next launch something else to scan');
      expect(tables, isNot(contains('feed_group_cursor')),
          reason: 'Same as the chunk table: dead schema should not survive an upgrade');
    });

    test('Should add the account user id column without losing the login', () async {
      final legacy = await openDatabase(databaseName, version: 29, onCreate: (db, version) async {
        await db.execute('CREATE TABLE accounts (id TEXT PRIMARY KEY, auth_header VARCHAR, '
            'screen_name VARCHAR DEFAULT NULL, last_not_found_at TEXT DEFAULT NULL, '
            'consecutive_not_found INTEGER DEFAULT 0, is_active INTEGER DEFAULT 0)');
      });
      await legacy.insert(
          'accounts', {'id': 'ct0', 'auth_header': '{}', 'screen_name': 'dogs', 'is_active': 1});
      await legacy.close();

      await Repository().migrate();

      final db = await Repository.readOnly();
      final columns = (await db.rawQuery('PRAGMA table_info($tableAccounts)'))
          .map((row) => row['name'])
          .toSet();
      final rows = await db.query(tableAccounts);
      await db.close();

      expect(columns, contains('user_id'),
          reason: 'The likes tab reads the numeric id from this column; without it every launch '
              'pays for the profile resolution again');
      expect(rows.single['screen_name'], 'dogs',
          reason: 'Adding the column must keep the logged-in account, not rebuild the table');
      expect(rows.single['user_id'], isNull,
          reason: 'Accounts that existed before the column carry no id yet — the likes tab fills '
              'it in on first use');
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

  // The footer of every visible post asks these on each rebuild, so they are
  // served from an index rather than a scan. What follows pins the part an index
  // can get wrong: a mutation whose new list never reached the store, leaving
  // the answer one step behind what is on screen.
  group('The post footer lookups', () {
    setUp(() async {
      await deleteDatabase(databaseName);
      await Repository().migrate();
    });

    test('Should report a like and an unlike without a reload', () async {
      final liked = LikedTweetModel();

      await liked.likeTweet('t1', 'u1', {'id_str': 't1'});
      expect(liked.isLiked('t1'), isTrue,
          reason: 'The heart fills on the tap, so the lookup cannot depend on a refresh');

      await liked.unlikeTweet('t1');
      expect(liked.isLiked('t1'), isFalse,
          reason: 'And it has to empty again, with the list the index was built from');
    });
  });

}
