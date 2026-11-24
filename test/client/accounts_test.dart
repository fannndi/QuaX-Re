import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/session_crypto.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    databaseName = 'quax_accounts_test.db';
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SessionCrypto.debugOverride = (method, arguments) async {
      final text = arguments['text'] as String;
      if (method == 'encryptSession') {
        return '${SessionCrypto.encryptedPrefix}${base64Url.encode(utf8.encode(text))}';
      }
      final encoded = text.startsWith(SessionCrypto.encryptedPrefix)
          ? text.substring(SessionCrypto.encryptedPrefix.length)
          : text;
      return utf8.decode(base64Url.decode(encoded));
    };
  });

  tearDown(() async {
    SessionCrypto.debugOverride = null;
    activeAccount.value = null;
    await deleteDatabase(databaseName);
  });

  group('saveLoggedInAccount()', () {
    test(
      'Should keep the active flag and local owner across a re-login',
      () async {
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
        expect(
          rows,
          hasLength(1),
          reason:
              'A re-login replaces the old row instead of leaving a second login for the same '
              'handle behind',
        );
        expect(rows.single['id'], 'new-ct0');
        expect(
          rows.single['is_active'],
          1,
          reason:
              'The account was the active one before the re-login; dropping the flag left every '
              'account-scoped feed with no account until the login screen wrote it back',
        );
        expect(
          rows.single[columnLocalId],
          'local-dogs',
          reason:
              'Local likes are keyed on this id and must survive the new ct0',
        );
      },
    );
  });

  group('loadActiveAccount()', () {
    test(
      'Should promote the first account when every row lost its active flag',
      () async {
        await Repository().migrate();
        final db = await Repository.writable();
        await db.insert(
          tableAccounts,
          Account(
            id: 'ct0-a',
            authHeader: '{}',
            screenName: 'a',
            localId: 'local-a',
          ).toMap(),
        );
        await db.insert(
          tableAccounts,
          Account(
            id: 'ct0-b',
            authHeader: '{}',
            screenName: 'b',
            localId: 'local-b',
          ).toMap(),
        );

        await loadActiveAccount();

        expect(
          activeAccount.value?.id,
          'ct0-a',
          reason:
              'With rows present but no active flag, the app has to pick one instead of '
              'pretending there are no accounts and sending the reader to the login screen',
        );
        final active = await db.query(tableAccounts, where: 'is_active = 1');
        expect(
          active,
          hasLength(1),
          reason: 'The repair has to be persisted, not only kept in memory',
        );
        expect(active.single['id'], 'ct0-a');
      },
    );
  });

  group('account identity and session storage', () {
    test('Should let the numeric user id override a reused handle', () async {
      await Repository().migrate();
      final db = await Repository.writable();
      await db.insert(
        tableAccounts,
        Account(
          id: 'old-alice',
          authHeader: '{}',
          screenName: 'alice',
          userId: '101',
          localId: 'local-alice',
        ).toMap(),
      );
      await db.insert(
        tableAccounts,
        Account(
          id: 'old-bob',
          authHeader: '{}',
          screenName: 'bob',
          userId: '102',
          localId: 'local-bob',
        ).toMap(),
      );

      await saveLoggedInAccount(
        id: 'new-session',
        screenName: 'bob',
        userId: '101',
        authHeader: '{}',
      );

      final rows = await db.query(tableAccounts, orderBy: 'id');
      expect(
        rows,
        hasLength(2),
        reason:
            'The numeric id identifies the re-login; the different account that happens '
            'to reuse the new handle must not be deleted',
      );
      expect(
        rows.map((row) => row['id']),
        ['new-session', 'old-bob'],
        reason: 'Only the numeric match is replaced; the handle-only match survives',
      );
      expect(
        rows.firstWhere((row) => row['id'] == 'new-session')[columnLocalId],
        'local-alice',
        reason: 'The numeric match carries the stable likes owner',
      );
      expect(
        rows.firstWhere((row) => row['id'] == 'new-session')['screen_name'],
        'bob',
        reason: 'The fresh login profile replaces the matched row profile',
      );
    });

    test(
      'Should not merge by handle when the new login has a numeric id',
      () async {
        await Repository().migrate();
        await saveLoggedInAccount(
          id: 'old',
          screenName: 'alice',
          userId: '101',
          authHeader: '{}',
        );

        await saveLoggedInAccount(
          id: 'new',
          screenName: 'alice',
          userId: '103',
          authHeader: '{}',
        );

        final rows = await Repository.read(
          (db) => db.query(tableAccounts, orderBy: 'id'),
        );
        expect(
          rows.map((row) => row['id']),
          ['new', 'old'],
          reason:
              'A handle reuse with a different numeric identity is a different account, not '
              'a re-login that may discard the old owner\'s likes',
        );
      },
    );

    test(
      'Should refuse to choose arbitrarily between conflicting legacy rows',
      () async {
        await Repository().migrate();
        final db = await Repository.writable();
        for (final id in ['one', 'two']) {
          await db.insert(
            tableAccounts,
            Account(
              id: id,
              authHeader: '{}',
              screenName: 'alice',
              localId: 'local-$id',
            ).toMap(),
          );
        }

        await expectLater(
          saveLoggedInAccount(id: 'new', screenName: 'alice', authHeader: '{}'),
          throwsStateError,
          reason:
              'Two rows with the same legacy handle have different owners; picking one would '
              'silently merge their likes',
        );
        expect(
          await db.query(tableAccounts),
          hasLength(2),
          reason: 'A rejected ambiguous match must leave both owners and sessions untouched',
        );
      },
    );

    test('Should encrypt session headers before persistence and expose plaintext Account objects', () async {
      await Repository().migrate();
      const header = '{"Cookie":"auth_token=SECRET;ct0=csrf"}';

      await saveLoggedInAccount(
        id: 'ct0',
        screenName: 'alice',
        authHeader: header,
      );

      final raw = await Repository.read((db) => db.query(tableAccounts));
      expect(
        raw.single['auth_header'],
        isNot(header),
        reason: 'The database row must not retain the live cookie in plaintext',
      );
      expect(
        SessionCrypto.isEncrypted(raw.single['auth_header'] as String),
        isTrue,
        reason: 'The stored value carries the version marker used for lazy migration',
      );
      expect(
        raw.single['auth_header'],
        isNot(contains('SECRET')),
        reason: 'A copied database must not expose the auth token',
      );
      final accounts = await getAccounts();
      expect(
        accounts.single.authHeader,
        header,
        reason: 'The request layer and vault exporter must keep receiving the original header',
      );
    });

    test('Should lazily re-encrypt a legacy plaintext row after a safe read', () async {
      await Repository().migrate();
      final db = await Repository.writable();
      const header = '{"Cookie":"auth_token=legacy;ct0=old"}';
      await db.insert(tableAccounts, {
        'id': 'legacy',
        'auth_header': header,
        'screen_name': 'alice',
        columnLocalId: 'local-legacy',
      });

      final accounts = await getAccounts();

      expect(
        accounts.single.authHeader,
        header,
        reason:
            'Reading a legacy row still returns the original plaintext header',
      );
      final raw = await Repository.read((db) => db.query(tableAccounts));
      expect(
        SessionCrypto.isEncrypted(raw.single['auth_header'] as String),
        isTrue,
        reason: 'A successful legacy read is the opportunity to stop storing cookies in plaintext',
      );
    });

    test('Should still read legacy plaintext when native encryption is unavailable', () async {
      SessionCrypto.debugOverride = null;
      await Repository().migrate();
      final db = await Repository.writable();
      const header = '{"Cookie":"auth_token=legacy;ct0=old"}';
      await db.insert(tableAccounts, {
        'id': 'legacy',
        'auth_header': header,
        'screen_name': 'alice',
        columnLocalId: 'local-legacy',
      });

      expect(
        (await getAccounts()).single.authHeader,
        header,
        reason: 'An older install must remain usable while the platform cipher is unavailable',
      );
      final raw = await Repository.read((db) => db.query(tableAccounts));
      expect(
        raw.single['auth_header'],
        header,
        reason:
            'A failed re-encryption must leave the only good session untouched',
      );
    });
  });

  group('importAccounts()', () {
    test(
      'Should match a restored numeric identity instead of a reused handle',
      () async {
        await Repository().migrate();
        final db = await Repository.writable();
        await db.insert(
          tableAccounts,
          Account(
            id: 'old-alice',
            authHeader: '{}',
            screenName: 'alice',
            userId: '101',
            localId: 'local-alice',
          ).toMap(),
        );
        await db.insert(
          tableAccounts,
          Account(
            id: 'old-bob',
            authHeader: '{}',
            screenName: 'bob',
            userId: '102',
            localId: 'local-bob',
          ).toMap(),
        );
        final restored = Account(
          id: 'restored',
          authHeader: '{}',
          screenName: 'bob',
          userId: '101',
          localId: 'backup-alice',
          isActive: true,
        );

        final result = await importAccounts([restored], replaceExisting: true);

        expect(
          result.replaced,
          1,
          reason: 'The restored numeric identity replaces exactly one existing session',
        );
        final rows = await db.query(tableAccounts, orderBy: 'id');
        expect(
          rows,
          hasLength(2),
          reason:
              'The account that merely reused the handle has a different numeric identity '
              'and must survive the restore',
        );
        final replaced = rows.firstWhere((row) => row['id'] == 'restored');
        expect(
          replaced[columnLocalId],
          'local-alice',
          reason: 'A session restore keeps the owner key used by existing local likes',
        );
        expect(
          replaced['is_active'],
          1,
          reason: 'The backup preferred account becomes active after restore',
        );
      },
    );

    test(
      'Should refuse an ambiguous numeric identity instead of picking a row',
      () async {
        await Repository().migrate();
        final db = await Repository.writable();
        for (final id in ['one', 'two']) {
          await db.insert(
            tableAccounts,
            Account(
              id: id,
              authHeader: '{}',
              screenName: id,
              userId: '101',
              localId: 'local-$id',
            ).toMap(),
          );
        }
        final restored = Account(
          id: 'restored',
          authHeader: '{}',
          screenName: 'alice',
          userId: '101',
          localId: 'backup',
        );

        await expectLater(
          importAccounts([restored], replaceExisting: true),
          throwsStateError,
          reason: 'An ambiguous numeric identity must abort instead of choosing an owner',
        );
        expect(
          await db.query(tableAccounts),
          hasLength(2),
          reason: 'A rejected ambiguous match must leave both owners and sessions untouched',
        );
      },
    );
  });

  group('recordAccountSuccess()', () {
    test('Should not let an older in-flight 200 clear a newer 401', () async {
      await Repository().migrate();
      final requestStartedAt = DateTime(2026, 11, 24, 12);
      final newerFailure = requestStartedAt.add(const Duration(minutes: 1));
      final db = await Repository.writable();
      await db.insert(
        tableAccounts,
        Account(
          id: 'ct0-a',
          authHeader: '{}',
          screenName: 'alice',
          localId: 'local-a',
          isActive: true,
          lastAuthErrorAt: newerFailure,
        ).toMap(),
      );
      await loadActiveAccount();
      expect(
        activeAccount.value?.sessionExpired,
        isTrue,
        reason: 'The newer 401 is the state the stale response must not erase',
      );

      final cleared = await recordAccountSuccess(
        'ct0-a',
        requestStartedAt: requestStartedAt,
      );

      expect(
        cleared,
        isFalse,
        reason: 'A response that started before the 401 cannot clear that newer failure',
      );
      final row = (await db.query(tableAccounts)).single;
      expect(
        row[columnLastAuthErrorAt],
        newerFailure.toIso8601String(),
        reason: 'The newer auth failure timestamp must remain persisted',
      );
      expect(
        activeAccount.value?.sessionExpired,
        isTrue,
        reason: 'The active account must keep its expired badge after the stale success',
      );
    });

    test('Should clear a failure when the request started after it', () async {
      await Repository().migrate();
      final failure = DateTime(2026, 11, 24, 12);
      final db = await Repository.writable();
      await db.insert(
        tableAccounts,
        Account(
          id: 'ct0-a',
          authHeader: '{}',
          screenName: 'alice',
          localId: 'local-a',
          isActive: true,
          lastAuthErrorAt: failure,
        ).toMap(),
      );
      await loadActiveAccount();

      final cleared = await recordAccountSuccess(
        'ct0-a',
        requestStartedAt: failure.add(const Duration(seconds: 1)),
      );

      expect(
        cleared,
        isTrue,
        reason: 'A request started after the failure is allowed to clear it',
      );
      final row = (await db.query(tableAccounts)).single;
      expect(
        row[columnLastAuthErrorAt],
        isNull,
        reason: 'The allowed clear must reach the persisted row',
      );
      expect(
        activeAccount.value?.sessionExpired,
        isFalse,
        reason: 'The in-memory badge follows the successful clear',
      );
    });

    test(
      'Should report false when a best-effort health write cannot run',
      () async {
        await Repository().migrate();
        final db = await Repository.writable();
        await db.execute('DROP TABLE $tableAccounts');

        final cleared = await recordAccountSuccess('ct0-a');

        expect(
          cleared,
          isFalse,
          reason:
              'Existing fire-and-forget callers must not receive a Future error from a '
              'failed best-effort health write',
        );
      },
    );

    test('Should keep unconditional clearing for callers that omit the timestamp', () async {
      await Repository().migrate();
      final db = await Repository.writable();
      await db.insert(
        tableAccounts,
        Account(
          id: 'ct0-a',
          authHeader: '{}',
          screenName: 'alice',
          localId: 'local-a',
          isActive: true,
          lastAuthErrorAt: DateTime(2026, 11, 24, 12),
        ).toMap(),
      );
      await loadActiveAccount();

      final cleared = await recordAccountSuccess('ct0-a');

      expect(
        cleared,
        isTrue,
        reason:
            'Existing callers keep the previous unconditional success behavior',
      );
      final row = (await db.query(tableAccounts)).single;
      expect(
        row[columnLastAuthErrorAt],
        isNull,
        reason:
            'Omitting the timestamp still clears the persisted session flag',
      );
      expect(
        activeAccount.value?.sessionExpired,
        isFalse,
        reason: 'Existing callers still refresh the in-memory session flag',
      );
    });
  });

  group('concurrent account switches', () {
    test('Should apply switches in call order and publish the last committed account', () async {
      await Repository().migrate();
      final db = await Repository.writable();
      for (final id in ['a', 'b', 'c']) {
        await db.insert(tableAccounts, {
          'id': id,
          'auth_header': '{}',
          'screen_name': id,
          columnLocalId: 'local-$id',
        });
      }
      final revision = accountsRevision.value;

      await Future.wait([
        setActiveAccount('a'),
        setActiveAccount('b'),
        setActiveAccount('c'),
      ]);

      expect(
        activeAccount.value?.id,
        'c',
        reason: 'A later call must win even when earlier database work is still in flight',
      );
      expect(
        (await getActiveAccount())?.id,
        'c',
        reason: 'The persisted active flag must agree with the last published account',
      );
      expect(
        accountsRevision.value,
        revision + 3,
        reason: 'Each real switch is published once, in the same order as the commits',
      );
    });
  });
}
