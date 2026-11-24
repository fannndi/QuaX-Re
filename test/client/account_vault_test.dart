import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pref/pref.dart';
import 'package:quax/client/account_vault.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/session_crypto.dart';
import 'package:quax/client/vault_codec.dart';
import 'package:quax/constants.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FailingWriteAccountVault extends AccountVault {
  _FailingWriteAccountVault({required super.codec});

  @override
  Future<AccountVaultWriteResult> write({
    required String vaultRoot,
    required String passphrase,
  }) async => throw StateError('injected account vault write failure');
}

class _FailingAdoptAccountVault extends AccountVault {
  _FailingAdoptAccountVault({required super.codec});

  @override
  Future<void> adoptFile({
    required String sourcePath,
    required String vaultRoot,
    required String passphrase,
  }) async => throw StateError('injected account vault adoption failure');
}

void main() {
  const passphrase = 'correct horse battery';
  late Directory temp;
  late String vaultRoot;

  setUpAll(() {
    databaseName = 'quax_account_vault_test.db';
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
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
    await deleteDatabase(databaseName);
    await Repository().migrate();
    activeAccount.value = null;
    accountsRevision.value = 0;
    temp = await Directory.systemTemp.createTemp('quax-account-vault-');
    vaultRoot = p.join(temp.path, 'backups');
    await Directory(vaultRoot).create();
  });

  tearDown(() async {
    SessionCrypto.debugOverride = null;
    await deleteDatabase(databaseName);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  String authHeader(String name) => jsonEncode({
    'Cookie': 'auth_token=token-$name;ct0=csrf-$name;gt=1;att=1',
    'authorization': bearerToken,
    'x-csrf-token': 'csrf-$name',
  });

  Future<void> addAccount(
    String name, {
    bool active = false,
    String? handle,
    String? userId,
    String? localId,
  }) async {
    final db = await Repository.writable();
    await db.insert(
      tableAccounts,
      Account(
        id: 'csrf-$name',
        authHeader: authHeader(name),
        screenName: handle ?? name,
        userId: userId ?? '100${name.codeUnitAt(0)}',
        localId: localId ?? 'local-$name',
        isActive: active,
      ).toMap(),
    );
  }

  test('Should write the vault into the QuaXAccount folder and read the sessions back', () async {
    await addAccount('a', active: true, userId: '101', handle: 'alice');
    await addAccount('b', userId: '102', handle: 'bob');

    final result = await AccountVault().write(
      vaultRoot: vaultRoot,
      passphrase: passphrase,
    );

    expect(result.accounts, 2);
    expect(File(accountVaultPathFor(vaultRoot)!).existsSync(), isTrue);
    expect(
      File(p.join(accountFolderPathFor(vaultRoot)!, '.nomedia')).existsSync(),
      isTrue,
      reason: 'The account folder must not be indexed as media',
    );
    expect(
      p.basename(p.dirname(accountVaultPathFor(vaultRoot)!)),
      accountFolderName,
    );

    final text = File(accountVaultPathFor(vaultRoot)!).readAsStringSync();
    expect(
      text,
      isNot(contains('auth_token')),
      reason: 'A vault copied off the device must not hand over a live cookie',
    );
    expect(text, isNot(contains('alice')), reason: 'Handles are encrypted too');

    final read = await AccountVault().read(
      vaultRoot: vaultRoot,
      passphrase: passphrase,
    );
    expect(
      read.accounts.map((a) => a.screenName),
      containsAll(['alice', 'bob']),
    );
    expect(
      read.accounts.firstWhere((a) => a.isActive).screenName,
      'alice',
      reason: 'The active account is part of the backup so a restore comes back on the same login',
    );
    final alice = read.accounts.firstWhere((a) => a.screenName == 'alice');
    expect(
      alice.localId,
      'local-a',
      reason: 'The stable local id lets per-account likes reconnect after a restore',
    );
    expect(alice.userId, '101');
    final header =
        jsonDecode(alice.authHeader as String) as Map<String, dynamic>;
    expect(
      header['authorization'],
      bearerToken,
      reason: 'The current app bearer replaces whatever the backup was written with',
    );
    expect(header['Cookie'], contains('auth_token=token-a'));
  });

  test(
    'Should import into an empty database and keep the active account',
    () async {
      await addAccount('a', active: true, userId: '101', handle: 'alice');
      await addAccount('b', userId: '102', handle: 'bob');
      await AccountVault().write(vaultRoot: vaultRoot, passphrase: passphrase);

      final db = await Repository.writable();
      await db.delete(tableAccounts);
      activeAccount.value = null;

      final read = await AccountVault().read(
        vaultRoot: vaultRoot,
        passphrase: passphrase,
      );
      final imported = await importAccounts(read.accounts);

      expect(imported.imported, 2);
      expect(imported.replaced, 0);
      expect(imported.kept, 0);

      final rows = await Repository.read(
        (db) => db.query(tableAccounts, orderBy: 'screen_name'),
      );
      expect(rows, hasLength(2));
      expect(
        rows.map((row) => row[columnLocalId]),
        containsAll(['local-a', 'local-b']),
      );
      expect(
        activeAccount.value?.screenName,
        'alice',
        reason: 'A restore is explicit, so the backup\'s active account should drive the feeds',
      );
    },
  );

  test('Should rewrite the merged vault when an all-kept restore changes the preferred account', () async {
    await addAccount('a', active: true, userId: '101', handle: 'alice');
    await addAccount('b', userId: '102', handle: 'bob');
    await loadActiveAccount();
    final local = await getAccounts();
    final restored = local
        .map(
          (account) => Account(
            id: account.id,
            authHeader: account.authHeader,
            screenName: account.screenName,
            userId: account.userId,
            localId: account.localId,
            isActive: account.screenName == 'bob',
          ),
        )
        .toList();
    final prefs = PrefServiceCache(cache: {optionAccountVaultDirty: false});
    final dirtyTransitions = <bool>[];

    final imported = await restoreAccountsAndRewriteVault(
      accountVault: AccountVault(codec: const VaultCodec(iterations: 10000)),
      accounts: restored,
      replaceExisting: false,
      vaultRoot: vaultRoot,
      passphrase: passphrase,
      saveDirty: (dirty) async {
        dirtyTransitions.add(dirty);
        await prefs.set<bool>(optionAccountVaultDirty, dirty);
      },
    );

    expect(
      imported.restored,
      0,
      reason: 'Every local session is kept when replacement is disabled',
    );
    expect(
      imported.kept,
      2,
      reason: 'The restore is nonempty even though it replaces no session rows',
    );
    expect(
      dirtyTransitions,
      [true, false],
      reason:
          'The merged database is dirty until its fresh vault write succeeds',
    );
    expect(
      prefs.get<bool>(optionAccountVaultDirty),
      isFalse,
      reason: 'A successful merged rewrite makes the backup current again',
    );
    expect(
      activeAccount.value?.id,
      'csrf-b',
      reason: 'The backup preferred account becomes active even when sessions are kept',
    );
    final read = await AccountVault().read(
      vaultRoot: vaultRoot,
      passphrase: passphrase,
    );
    expect(
      read.accounts.firstWhere((account) => account.isActive).screenName,
      'bob',
      reason: 'The rewritten vault must persist the newly preferred account',
    );
  });

  test(
    'Should leave the backup dirty when the merged vault write fails',
    () async {
      await addAccount('a', active: true, userId: '101', handle: 'alice');
      await loadActiveAccount();
      final restored = await getAccounts();
      final prefs = PrefServiceCache(cache: {optionAccountVaultDirty: false});

      await expectLater(
        restoreAccountsAndRewriteVault(
          accountVault: _FailingWriteAccountVault(
            codec: const VaultCodec(iterations: 10000),
          ),
          accounts: restored,
          replaceExisting: false,
          vaultRoot: vaultRoot,
          passphrase: passphrase,
          saveDirty: (dirty) async {
            await prefs.set<bool>(optionAccountVaultDirty, dirty);
          },
        ),
        throwsStateError,
        reason: 'The injected write failure must reach the restore caller',
      );

      expect(
        prefs.get<bool>(optionAccountVaultDirty),
        isTrue,
        reason:
            'The import already changed preferred-account state, so a failed rewrite '
            'must not leave the backup marked clean',
      );
    },
  );

  test(
    'Should leave the backup dirty when file adoption fails after import',
    () async {
      await addAccount('a', active: true, userId: '101', handle: 'alice');
      await loadActiveAccount();
      final restored = await getAccounts();
      final prefs = PrefServiceCache(cache: {optionAccountVaultDirty: false});

      await expectLater(
        restoreAccountsAndRewriteVault(
          accountVault: _FailingAdoptAccountVault(
            codec: const VaultCodec(iterations: 10000),
          ),
          accounts: restored,
          replaceExisting: false,
          vaultRoot: vaultRoot,
          passphrase: passphrase,
          sourcePath: p.join(temp.path, 'picked.quaxvault'),
          saveDirty: (dirty) async {
            await prefs.set<bool>(optionAccountVaultDirty, dirty);
          },
        ),
        throwsStateError,
        reason:
            'The injected adoption failure must reach the file-import caller',
      );

      expect(
        prefs.get<bool>(optionAccountVaultDirty),
        isTrue,
        reason: 'A failed fresh merged vault must leave the backup out of date',
      );
    },
  );

  test('Should fall back to .bak for corrupt inner account payloads', () async {
    await addAccount('a', active: true, handle: 'alice');
    const codec = VaultCodec(iterations: 10000);
    final vault = AccountVault(codec: codec);
    await vault.write(vaultRoot: vaultRoot, passphrase: passphrase);
    await vault.write(vaultRoot: vaultRoot, passphrase: passphrase);
    final primary = File(accountVaultPathFor(vaultRoot)!);
    final corruptPayloads = <Map<String, dynamic>>[
      {'format': 'wrong.format', 'version': 1, 'accounts': []},
      {'version': 1, 'accounts': []},
      {'format': 'quax.accounts', 'accounts': []},
      {'format': 'quax.accounts', 'version': '1', 'accounts': []},
      {'format': 'quax.accounts', 'version': 0, 'accounts': []},
    ];

    for (final payload in corruptPayloads) {
      await primary.writeAsString(
        await codec.encrypt(
          passphrase: passphrase,
          kind: 'accounts',
          payload: payload,
        ),
      );
      final read = await vault.read(
        vaultRoot: vaultRoot,
        passphrase: passphrase,
      );
      expect(
        read.accounts.single.screenName,
        'alice',
        reason:
            'Wrong inner formats and invalid versions are corruption, so the valid '
            '.bak must remain a recovery source',
      );
    }

    await primary.writeAsString(
      await codec.encrypt(
        passphrase: passphrase,
        kind: 'accounts',
        payload: {'format': 'quax.accounts', 'version': 2, 'accounts': []},
      ),
    );
    await expectLater(
      vault.read(vaultRoot: vaultRoot, passphrase: passphrase),
      throwsA(
        isA<VaultException>().having(
          (error) => error.failure,
          'failure',
          VaultFailure.unsupportedVersion,
        ),
      ),
      reason: 'Only a genuinely newer inner payload version may block backup fallback',
    );
  });

  test(
    'Should keep the current session unless the restore asks to replace it',
    () async {
      await addAccount('a', active: true, userId: '101', handle: 'alice');
      final vault = AccountVault();
      await vault.write(vaultRoot: vaultRoot, passphrase: passphrase);

      final db = await Repository.writable();
      await db.update(
        tableAccounts,
        {'auth_header': authHeader('newer')},
        where: 'id = ?',
        whereArgs: ['csrf-a'],
      );
      await db.insert(tableLikedTweet, {'id': 'liked', 'content': '{}'});
      await db.insert(tableAccountLike, {
        columnAccountLocalId: 'local-a',
        columnTweetId: 'liked',
      });

      final read = await vault.read(
        vaultRoot: vaultRoot,
        passphrase: passphrase,
      );
      final kept = await importAccounts(read.accounts);
      expect(kept.kept, 1);
      expect(kept.replaced, 0);
      final keptRow = (await Repository.read((db) => db.query(tableAccounts)))
          .single;
      expect(
        keptRow['auth_header'],
        authHeader('newer'),
        reason: 'An import by default must not overwrite a session that may be newer than the file',
      );

      final replaced = await importAccounts(
        read.accounts,
        replaceExisting: true,
      );
      expect(replaced.replaced, 1);
      final replacedRow = (await getAccounts()).single;
      expect(
        replacedRow.authHeader,
        authHeader('a'),
        reason: 'The public Account object still exposes the restored plaintext header',
      );
      expect(
        replacedRow.localId,
        'local-a',
        reason: 'Replacing the session must keep the owner key, or the existing local likes detach',
      );
      final likes = await Repository.read((db) => db.query(tableAccountLike));
      expect(
        likes,
        hasLength(1),
        reason: 'The local like saved under this account must survive a session restore',
      );
    },
  );

  test(
    'Should report invalid entries and reject a vault with none usable',
    () async {
      await ensureAccountFolder(vaultRoot);
      final codec = VaultCodec(iterations: 10000);
      final envelope = await codec.encrypt(
        passphrase: passphrase,
        kind: 'accounts',
        payload: {
          'format': 'quax.accounts',
          'version': 1,
          'accounts': [
            {
              'screen_name': 'alice',
              'user_id': '101',
              'local_id': 'local-a',
              'auth_header': authHeader('a'),
              'is_active': true,
            },
            {
              'screen_name': 'broken',
              'auth_header': jsonEncode({'Cookie': 'guest_id=1'}),
              'is_active': false,
            },
          ],
        },
      );
      File(accountVaultPathFor(vaultRoot)!).writeAsStringSync(envelope);

      final read = await AccountVault().read(
        vaultRoot: vaultRoot,
        passphrase: passphrase,
      );
      expect(
        read.accounts,
        hasLength(1),
        reason:
            'One bad account must not discard the good one in the same backup',
      );
      expect(
        read.invalid,
        1,
        reason: 'The UI needs to tell the reader that one entry could not be restored',
      );

      final noAccounts = await codec.encrypt(
        passphrase: passphrase,
        kind: 'accounts',
        payload: {
          'format': 'quax.accounts',
          'version': 1,
          'accounts': [
            {
              'screen_name': 'broken',
              'auth_header': jsonEncode({'Cookie': 'guest_id=1'}),
            },
          ],
        },
      );
      File(accountVaultPathFor(vaultRoot)!).writeAsStringSync(noAccounts);

      await expectLater(
        AccountVault().read(vaultRoot: vaultRoot, passphrase: passphrase),
        throwsA(
          isA<VaultException>().having(
            (e) => e.failure,
            'failure',
            VaultFailure.corrupt,
          ),
        ),
        reason: 'A vault with no usable session is not a successful restore',
      );
    },
  );

  test('Should fall back to .bak when the primary file is damaged', () async {
    await addAccount('a', active: true, handle: 'alice');
    final vault = AccountVault();
    await vault.write(vaultRoot: vaultRoot, passphrase: passphrase);
    await vault.write(vaultRoot: vaultRoot, passphrase: passphrase);

    final primary = File(accountVaultPathFor(vaultRoot)!);
    primary.writeAsStringSync('{not json');

    final read = await vault.read(vaultRoot: vaultRoot, passphrase: passphrase);
    expect(
      read.accounts.single.screenName,
      'alice',
      reason: 'A write that was cut off must not make the previous backup unreachable',
    );
  });

  test(
    'Should fall back to .bak when the primary fails its authentication tag',
    () async {
      await addAccount('a', active: true, handle: 'alice');
      final vault = AccountVault();
      await vault.write(vaultRoot: vaultRoot, passphrase: passphrase);
      await vault.write(vaultRoot: vaultRoot, passphrase: passphrase);

      final primary = File(accountVaultPathFor(vaultRoot)!);
      final envelope =
          jsonDecode(primary.readAsStringSync()) as Map<String, dynamic>;
      final mac = envelope['mac'] as String;
      // Flip one character while keeping the envelope well-formed: a GCM tag
      // failure looks exactly like a wrong passphrase.
      envelope['mac'] = '${mac[0] == 'A' ? 'B' : 'A'}${mac.substring(1)}';
      primary.writeAsStringSync(jsonEncode(envelope));

      final read = await vault.read(
        vaultRoot: vaultRoot,
        passphrase: passphrase,
      );
      expect(
        read.accounts.single.screenName,
        'alice',
        reason: 'One flipped byte must not hide the good backup behind a wrong-passphrase error',
      );
    },
  );

  test(
    'Should not fall back to .bak when the primary uses a newer format',
    () async {
      await addAccount('a', active: true, handle: 'alice');
      final vault = AccountVault();
      await vault.write(vaultRoot: vaultRoot, passphrase: passphrase);
      await vault.write(vaultRoot: vaultRoot, passphrase: passphrase);

      final primary = File(accountVaultPathFor(vaultRoot)!);
      primary.writeAsStringSync(
        jsonEncode({
          'format': VaultCodec.format,
          'version': VaultCodec.currentVersion + 1,
          'kind': 'accounts',
        }),
      );

      await expectLater(
        vault.read(vaultRoot: vaultRoot, passphrase: passphrase),
        throwsA(
          isA<VaultException>().having(
            (e) => e.failure,
            'failure',
            VaultFailure.unsupportedVersion,
          ),
        ),
        reason:
            'Restoring the older .bak instead would report success while silently replacing '
            'the newer account list with a stale one',
      );
    },
  );

  test('Should report a missing or wrong-passphrase vault clearly', () async {
    await expectLater(
      AccountVault().read(vaultRoot: vaultRoot, passphrase: passphrase),
      throwsA(isA<AccountVaultNotFound>()),
    );

    await addAccount('a', handle: 'alice');
    await AccountVault().write(vaultRoot: vaultRoot, passphrase: passphrase);

    await expectLater(
      AccountVault().read(
        vaultRoot: vaultRoot,
        passphrase: 'wrong horse battery',
      ),
      throwsA(
        isA<VaultException>().having(
          (e) => e.failure,
          'failure',
          VaultFailure.wrongPassphrase,
        ),
      ),
    );
  });

  test('Should change the passphrase and stop accepting the old one', () async {
    await addAccount('a', handle: 'alice');
    final vault = AccountVault();
    await vault.write(vaultRoot: vaultRoot, passphrase: passphrase);

    await vault.changePassphrase(
      vaultRoot: vaultRoot,
      oldPassphrase: passphrase,
      newPassphrase: 'new horse battery',
    );

    await expectLater(
      vault.read(vaultRoot: vaultRoot, passphrase: passphrase),
      throwsA(
        isA<VaultException>().having(
          (e) => e.failure,
          'failure',
          VaultFailure.wrongPassphrase,
        ),
      ),
      reason: 'The old passphrase must stop opening the vault after a change',
    );
    final read = await vault.read(
      vaultRoot: vaultRoot,
      passphrase: 'new horse battery',
    );
    expect(read.accounts.single.screenName, 'alice');
    expect(
      File(p.join(accountFolderPathFor(vaultRoot)!, accountVaultBackupFileName))
          .existsSync(),
      isFalse,
      reason:
          'The .bak copy was encrypted with the old passphrase, so keeping it would keep '
          'the old secret valid',
    );
  });

  test('Should re-authenticate an imported file and write the complete merged vault', () async {
    final other = await Directory.systemTemp.createTemp('quax-vault-other-');
    addTearDown(() async {
      if (await other.exists()) await other.delete(recursive: true);
    });
    final otherLibrary = p.join(other.path, 'QuaXLibrary');
    await addAccount('a', handle: 'alice');
    await AccountVault().write(vaultRoot: otherLibrary, passphrase: passphrase);
    final importedPath = accountVaultPathFor(otherLibrary)!;

    final read = await AccountVault().readFile(
      filePath: importedPath,
      passphrase: passphrase,
    );
    expect(
      read.accounts.single.screenName,
      'alice',
      reason: 'The picked source file decrypts to the expected account',
    );
    await addAccount('local', handle: 'localonly', localId: 'local-only');

    await expectLater(
      AccountVault().adoptFile(
        sourcePath: importedPath,
        vaultRoot: vaultRoot,
        passphrase: 'wrong horse battery',
      ),
      throwsA(
        isA<VaultException>().having(
          (error) => error.failure,
          'failure',
          VaultFailure.wrongPassphrase,
        ),
      ),
      reason:
          'Adoption must authenticate the exact source bytes again instead of trusting an '
          'earlier read of a file that may have changed',
    );
    expect(
      await AccountVault().exists(vaultRoot),
      isFalse,
      reason:
          'Failed re-authentication must not create or replace the fixed vault',
    );

    await importAccounts(read.accounts, replaceExisting: true);
    await AccountVault().adoptFile(
      sourcePath: importedPath,
      vaultRoot: vaultRoot,
      passphrase: passphrase,
    );

    expect(
      await AccountVault().exists(vaultRoot),
      isTrue,
      reason: 'The next onboarding should find the imported backup without asking for the file again',
    );
    expect(
      await AccountVault().lastSaved(vaultRoot),
      isNotNull,
      reason: 'A freshly written adopted vault has a recovery timestamp',
    );
    final restored = await AccountVault().read(
      vaultRoot: vaultRoot,
      passphrase: passphrase,
    );
    expect(
      restored.accounts.map((account) => account.screenName),
      containsAll(['alice', 'localonly']),
      reason:
          'Copying the older source file after a merge would drop local accounts that were '
          'not in that source; adoption must write a fresh complete vault',
    );
  });

  test('Should treat a backup-only vault as present and recoverable', () async {
    await addAccount('a', handle: 'alice');
    final vault = AccountVault();
    await vault.write(vaultRoot: vaultRoot, passphrase: passphrase);
    await vault.write(vaultRoot: vaultRoot, passphrase: passphrase);
    final primary = File(accountVaultPathFor(vaultRoot)!);
    final backup = File('${primary.path}.bak');
    final saved = await backup.stat();

    await primary.delete();

    expect(
      await vault.exists(vaultRoot),
      isTrue,
      reason: 'Recovery UI must still offer restore when only the rollback copy remains',
    );
    expect(
      await vault.lastSaved(vaultRoot),
      saved.modified,
      reason: 'The recovery timestamp comes from the surviving backup',
    );
    expect(
      (await vault.read(
        vaultRoot: vaultRoot,
        passphrase: passphrase,
      )).accounts.single.screenName,
      'alice',
      reason: 'The backup-only vault still restores the saved account',
    );
  });

  test(
    'Should refuse to write more than the supported account count',
    () async {
      await Repository().migrate();
      final db = await Repository.writable();
      for (var i = 0; i < 51; i++) {
        await db.insert(tableAccounts, {
          'id': 'ct0-$i',
          'auth_header': '{}',
          'screen_name': 'user$i',
          columnLocalId: 'local-$i',
        });
      }

      await expectLater(
        AccountVault().write(vaultRoot: vaultRoot, passphrase: passphrase),
        throwsStateError,
        reason: 'The reader must not create a vault that its own parser refuses to restore',
      );
      expect(
        await AccountVault().exists(vaultRoot),
        isFalse,
        reason:
            'An oversized account set must not leave a partial vault behind',
      );
    },
  );

  test('Should remove both the vault and its backup', () async {
    await addAccount('a', handle: 'alice');
    final vault = AccountVault();
    await vault.write(vaultRoot: vaultRoot, passphrase: passphrase);
    await vault.write(vaultRoot: vaultRoot, passphrase: passphrase);

    await vault.delete(vaultRoot);

    expect(File(accountVaultPathFor(vaultRoot)!).existsSync(), isFalse);
    expect(
      File(p.join(accountFolderPathFor(vaultRoot)!, accountVaultBackupFileName))
          .existsSync(),
      isFalse,
    );
  });
}
