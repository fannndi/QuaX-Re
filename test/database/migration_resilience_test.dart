import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/database/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
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
