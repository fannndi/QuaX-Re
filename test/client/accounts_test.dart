import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    databaseName = 'quax_accounts_test.db';
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    activeAccount.value = null;
    await deleteDatabase(databaseName);
  });

  group('saveLoggedInAccount()', () {
    test('Should keep the active flag and local owner across a re-login', () async {
      await Repository().migrate();
      final db = await Repository.writable();
      await db.insert(
        tableAccounts,
        Account(
          id: 'old-ct0',
          authHeader: '{}',
          screenName: 'dogs',
          localId: 'local-dogs',
          isActive: true,
        ).toMap(),
      );

      await saveLoggedInAccount(
        id: 'new-ct0',
        screenName: 'dogs',
        authHeader: '{}',
      );

      final rows = await db.query(tableAccounts);
      expect(rows, hasLength(1),
          reason: 'A re-login replaces the old row instead of leaving a second login for the same '
              'handle behind');
      expect(rows.single['id'], 'new-ct0');
      expect(rows.single['is_active'], 1,
          reason: 'The account was the active one before the re-login; dropping the flag left every '
              'account-scoped feed with no account until the login screen wrote it back');
      expect(rows.single[columnLocalId], 'local-dogs',
          reason: 'Local likes are keyed on this id and must survive the new ct0');
    });
  });

  group('loadActiveAccount()', () {
    test('Should promote the first account when every row lost its active flag', () async {
      await Repository().migrate();
      final db = await Repository.writable();
      await db.insert(
        tableAccounts,
        Account(id: 'ct0-a', authHeader: '{}', screenName: 'a', localId: 'local-a').toMap(),
      );
      await db.insert(
        tableAccounts,
        Account(id: 'ct0-b', authHeader: '{}', screenName: 'b', localId: 'local-b').toMap(),
      );

      await loadActiveAccount();

      expect(activeAccount.value?.id, 'ct0-a',
          reason: 'With rows present but no active flag, the app has to pick one instead of '
              'pretending there are no accounts and sending the reader to the login screen');
      final active = await db.query(tableAccounts, where: 'is_active = 1');
      expect(active, hasLength(1),
          reason: 'The repair has to be persisted, not only kept in memory');
      expect(active.single['id'], 'ct0-a');
    });
  });
}
