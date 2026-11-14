import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/database/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    databaseName = 'quax_migration_resilience_test.db';
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    await deleteDatabase(databaseName);
  });

  Future<Database> openAt31() {
    return openDatabase(databaseName, version: 31, onCreate: (db, version) async {
      await db.execute('CREATE TABLE $tableAccounts ('
          'id TEXT PRIMARY KEY, auth_header VARCHAR, screen_name VARCHAR DEFAULT NULL, '
          'last_not_found_at TEXT DEFAULT NULL, consecutive_not_found INTEGER DEFAULT 0, '
          'is_active INTEGER DEFAULT 0, user_id VARCHAR DEFAULT NULL)');
      await db.execute('CREATE TABLE $tableLikedTweet ('
          'id VARCHAR PRIMARY KEY, content TEXT NOT NULL, user_id VARCHAR DEFAULT NULL, '
          'liked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)');
    });
  }

  test('Should give each account a stable id and adopt the old likes', () async {
    final legacy = await openAt31();
    await legacy.insert(tableAccounts,
        {'id': 'ct0-a', 'auth_header': '{}', 'screen_name': 'alice', 'is_active': 1});
    await legacy.insert(tableAccounts,
        {'id': 'ct0-b', 'auth_header': '{}', 'screen_name': 'bob', 'is_active': 0});
    for (var i = 0; i < 3; i++) {
      await legacy.insert(tableLikedTweet, {
        'id': 't$i',
        'content': '{}',
        'liked_at': DateTime.utc(2026, 1, 1).add(Duration(minutes: i)).toIso8601String(),
      });
    }
    await legacy.close();

    await Repository().migrate();

    final db = await Repository.readOnly();
    final accounts = await db.query(tableAccounts, orderBy: 'screen_name');
    final owners = await db.query(tableAccountLike);
    final likes = await db.query(tableLikedTweet);
    final version = await db.getVersion();
    await db.close();

    expect(version, 33);
    expect(accounts, hasLength(2), reason: 'The upgrade must not drop a login');
    final localIds = accounts.map((row) => row[columnLocalId] as String?).toList();
    expect(localIds.every((id) => id != null && id.isNotEmpty), isTrue,
        reason: 'Every account needs an owner key before per-account likes can be written');
    expect(localIds.toSet(), hasLength(2),
        reason: 'Two accounts with the same local id would see each other\'s likes');

    expect(likes, hasLength(3), reason: 'The tweet bodies are kept, not moved or duplicated');
    expect(owners, hasLength(3),
        reason: 'The likes that existed before the column did are adopted by the active account');
    final activeLocalId = accounts.firstWhere((row) => row['is_active'] == 1)[columnLocalId];
    expect(owners.every((row) => row[columnAccountLocalId] == activeLocalId), isTrue,
        reason: 'The old schema did not record an owner; the active account is the least '
            'surprising guess');
  });

  test('Should survive old likes when there is no account to own them', () async {
    final legacy = await openAt31();
    await legacy.insert(tableLikedTweet, {'id': 't1', 'content': '{}'});
    await legacy.close();

    await Repository().migrate();

    final db = await Repository.readOnly();
    final owners = await db.query(tableAccountLike);
    final likes = await db.query(tableLikedTweet);
    await db.close();

    expect(owners, isEmpty,
        reason: 'There is no account to attribute the old like to, and inventing one would be '
            'worse than leaving it unowned');
    expect(likes, hasLength(1),
        reason: 'The migration must not delete data it cannot attribute');
  });

  test('Should skip malformed saved-tweet JSON during the backfill', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);

    await db.execute(
        'CREATE TABLE $tableSavedTweet (id VARCHAR PRIMARY KEY, content TEXT NOT NULL, user_id VARCHAR DEFAULT NULL)');
    await db.insert(tableSavedTweet, {
      'id': 'good',
      'content': jsonEncode({
        'user': {'id_str': 'u1'}
      })
    });
    await db.insert(tableSavedTweet, {'id': 'list', 'content': jsonEncode([1, 2])});
    await db.insert(tableSavedTweet, {'id': 'broken', 'content': '{not json'});
    await db.insert(tableSavedTweet, {'id': 'no-user', 'content': jsonEncode({'legacy': {}})});

    await backfillSavedTweetUserIds(db);

    final rows = await db.query(tableSavedTweet, orderBy: 'id');
    final byId = {for (final row in rows) row['id']: row['user_id']};

    expect(byId['good'], 'u1',
        reason: 'A well-formed saved tweet must still get its numeric user id');
    expect(byId['list'], isNull,
        reason: 'A JSON list is not a tweet object; it must not take the whole upgrade down');
    expect(byId['broken'], isNull,
        reason: 'Truncated JSON from a restore or a killed write must be skipped, not thrown');
    expect(byId['no-user'], isNull,
        reason: 'A tweet without a user object is simply left without a backfilled id');
  });
}
