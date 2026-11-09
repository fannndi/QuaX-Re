import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quax/client/account_vault.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/vault_codec.dart';
import 'package:quax/constants.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  const passphrase = 'correct horse battery';
  late Directory temp;
  late String libraryPath;

  setUpAll(() {
    databaseName = 'quax_account_vault_test.db';
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await deleteDatabase(databaseName);
    await Repository().migrate();
    activeAccount.value = null;
    accountsRevision.value = 0;
    temp = await Directory.systemTemp.createTemp('quax-account-vault-');
    libraryPath = p.join(temp.path, 'QuaXLibrary');
    await Directory(libraryPath).create();
  });

  tearDown(() async {
    await deleteDatabase(databaseName);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  String authHeader(String name) => jsonEncode({
        'Cookie': 'auth_token=token-$name;ct0=csrf-$name;gt=1;att=1',
        'authorization': bearerToken,
        'x-csrf-token': 'csrf-$name',
      });

  Future<void> addAccount(String name,
      {bool active = false, String? handle, String? userId, String? localId}) async {
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
        ).toMap());
  }

  test('Should write the vault beside QuaXLibrary and read the sessions back', () async {
    await addAccount('a', active: true, userId: '101', handle: 'alice');
    await addAccount('b', userId: '102', handle: 'bob');

    final result = await AccountVault().write(libraryPath: libraryPath, passphrase: passphrase);

    expect(result.accounts, 2);
    expect(File(accountVaultPathFor(libraryPath)!).existsSync(), isTrue);
    expect(File(p.join(accountFolderPathFor(libraryPath)!, '.nomedia')).existsSync(), isTrue,
        reason: 'The account folder must not be indexed as media');
    expect(p.basename(p.dirname(accountVaultPathFor(libraryPath)!)), accountFolderName);

    final text = File(accountVaultPathFor(libraryPath)!).readAsStringSync();
    expect(text, isNot(contains('auth_token')),
        reason: 'A vault copied off the device must not hand over a live cookie');
    expect(text, isNot(contains('alice')),
        reason: 'Handles are encrypted too');

    final read = await AccountVault().read(libraryPath: libraryPath, passphrase: passphrase);
    expect(read.accounts.map((a) => a.screenName), containsAll(['alice', 'bob']));
    expect(read.preferredActive?.screenName, 'alice',
        reason: 'The active account is part of the backup so a restore comes back on the same login');
    final alice = read.accounts.firstWhere((a) => a.screenName == 'alice');
    expect(alice.localId, 'local-a',
        reason: 'The stable local id lets per-account likes reconnect after a restore');
    expect(alice.userId, '101');
    final header = jsonDecode(alice.authHeader as String) as Map<String, dynamic>;
    expect(header['authorization'], bearerToken,
        reason: 'The current app bearer replaces whatever the backup was written with');
    expect(header['Cookie'], contains('auth_token=token-a'));
  });

  test('Should import into an empty database and keep the active account', () async {
    await addAccount('a', active: true, userId: '101', handle: 'alice');
    await addAccount('b', userId: '102', handle: 'bob');
    await AccountVault().write(libraryPath: libraryPath, passphrase: passphrase);

    final db = await Repository.writable();
    await db.delete(tableAccounts);
    activeAccount.value = null;

    final read = await AccountVault().read(libraryPath: libraryPath, passphrase: passphrase);
    final imported = await importAccounts(read.accounts);

    expect(imported.imported, 2);
    expect(imported.replaced, 0);
    expect(imported.kept, 0);

    final rows = await Repository.read((db) => db.query(tableAccounts, orderBy: 'screen_name'));
    expect(rows, hasLength(2));
    expect(rows.map((row) => row[columnLocalId]), containsAll(['local-a', 'local-b']));
    expect(activeAccount.value?.screenName, 'alice',
        reason: 'A restore is explicit, so the backup\'s active account should drive the feeds');
  });

  test('Should keep the current session unless the restore asks to replace it', () async {
    await addAccount('a', active: true, userId: '101', handle: 'alice');
    final vault = AccountVault();
    await vault.write(libraryPath: libraryPath, passphrase: passphrase);

    final db = await Repository.writable();
    await db.update(tableAccounts, {'auth_header': authHeader('newer')}, where: 'id = ?', whereArgs: ['csrf-a']);
    await db.insert(tableLikedTweet, {'id': 'liked', 'content': '{}'});
    await db.insert(tableAccountLike,
        {columnAccountLocalId: 'local-a', columnTweetId: 'liked'});

    final read = await vault.read(libraryPath: libraryPath, passphrase: passphrase);
    final kept = await importAccounts(read.accounts);
    expect(kept.kept, 1);
    expect(kept.replaced, 0);
    final keptRow = (await Repository.read((db) => db.query(tableAccounts))).single;
    expect(keptRow['auth_header'], authHeader('newer'),
        reason: 'An import by default must not overwrite a session that may be newer than the file');

    final replaced = await importAccounts(read.accounts, replaceExisting: true);
    expect(replaced.replaced, 1);
    final replacedRow = (await Repository.read((db) => db.query(tableAccounts))).single;
    expect(replacedRow['auth_header'], authHeader('a'));
    expect(replacedRow[columnLocalId], 'local-a',
        reason: 'Replacing the session must keep the owner key, or the existing local likes detach');
    final likes = await Repository.read((db) => db.query(tableAccountLike));
    expect(likes, hasLength(1),
        reason: 'The local like saved under this account must survive a session restore');
  });

  test('Should report invalid entries and reject a vault with none usable', () async {
    await ensureAccountFolder(libraryPath);
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
    File(accountVaultPathFor(libraryPath)!).writeAsStringSync(envelope);

    final read = await AccountVault().read(libraryPath: libraryPath, passphrase: passphrase);
    expect(read.accounts, hasLength(1),
        reason: 'One bad account must not discard the good one in the same backup');
    expect(read.invalid, 1,
        reason: 'The UI needs to tell the reader that one entry could not be restored');

    final noAccounts = await codec.encrypt(
      passphrase: passphrase,
      kind: 'accounts',
      payload: {
        'format': 'quax.accounts',
        'version': 1,
        'accounts': [
          {'screen_name': 'broken', 'auth_header': jsonEncode({'Cookie': 'guest_id=1'})}
        ],
      },
    );
    File(accountVaultPathFor(libraryPath)!).writeAsStringSync(noAccounts);

    await expectLater(
        AccountVault().read(libraryPath: libraryPath, passphrase: passphrase),
        throwsA(isA<VaultException>()
            .having((e) => e.failure, 'failure', VaultFailure.corrupt)),
        reason: 'A vault with no usable session is not a successful restore');
  });

  test('Should fall back to .bak when the primary file is damaged', () async {
    await addAccount('a', active: true, handle: 'alice');
    final vault = AccountVault();
    await vault.write(libraryPath: libraryPath, passphrase: passphrase);
    await vault.write(libraryPath: libraryPath, passphrase: passphrase);

    final primary = File(accountVaultPathFor(libraryPath)!);
    primary.writeAsStringSync('{not json');

    final read = await vault.read(libraryPath: libraryPath, passphrase: passphrase);
    expect(read.accounts.single.screenName, 'alice',
        reason: 'A write that was cut off must not make the previous backup unreachable');
  });

  test('Should not fall back to .bak when the primary uses a newer format', () async {
    await addAccount('a', active: true, handle: 'alice');
    final vault = AccountVault();
    await vault.write(libraryPath: libraryPath, passphrase: passphrase);
    await vault.write(libraryPath: libraryPath, passphrase: passphrase);

    final primary = File(accountVaultPathFor(libraryPath)!);
    primary.writeAsStringSync(jsonEncode({
      'format': VaultCodec.format,
      'version': VaultCodec.currentVersion + 1,
      'kind': 'accounts',
    }));

    await expectLater(
      vault.read(libraryPath: libraryPath, passphrase: passphrase),
      throwsA(isA<VaultException>()
          .having((e) => e.failure, 'failure', VaultFailure.unsupportedVersion)),
      reason: 'Restoring the older .bak instead would report success while silently replacing '
          'the newer account list with a stale one',
    );
  });

  test('Should report a missing or wrong-passphrase vault clearly', () async {
    await expectLater(
        AccountVault().read(libraryPath: libraryPath, passphrase: passphrase),
        throwsA(isA<AccountVaultNotFound>()));

    await addAccount('a', handle: 'alice');
    await AccountVault().write(libraryPath: libraryPath, passphrase: passphrase);

    await expectLater(
        AccountVault().read(libraryPath: libraryPath, passphrase: 'wrong horse battery'),
        throwsA(isA<VaultException>()
            .having((e) => e.failure, 'failure', VaultFailure.wrongPassphrase)));
  });

  test('Should change the passphrase and stop accepting the old one', () async {
    await addAccount('a', handle: 'alice');
    final vault = AccountVault();
    await vault.write(libraryPath: libraryPath, passphrase: passphrase);

    await vault.changePassphrase(
        libraryPath: libraryPath, oldPassphrase: passphrase, newPassphrase: 'new horse battery');

    await expectLater(
        vault.read(libraryPath: libraryPath, passphrase: passphrase),
        throwsA(isA<VaultException>()
            .having((e) => e.failure, 'failure', VaultFailure.wrongPassphrase)),
        reason: 'The old passphrase must stop opening the vault after a change');
    final read = await vault.read(
        libraryPath: libraryPath, passphrase: 'new horse battery');
    expect(read.accounts.single.screenName, 'alice');
    expect(
        File(p.join(accountFolderPathFor(libraryPath)!, accountVaultBackupFileName)).existsSync(),
        isFalse,
        reason: 'The .bak copy was encrypted with the old passphrase, so keeping it would keep '
            'the old secret valid');
  });

  test('Should adopt an imported file into the fixed QuaXAccount path', () async {
    final other = await Directory.systemTemp.createTemp('quax-vault-other-');
    addTearDown(() async {
      if (await other.exists()) await other.delete(recursive: true);
    });
    final otherLibrary = p.join(other.path, 'QuaXLibrary');
    await addAccount('a', handle: 'alice');
    await AccountVault().write(libraryPath: otherLibrary, passphrase: passphrase);
    final importedPath = accountVaultPathFor(otherLibrary)!;

    final read = await AccountVault().readFile(filePath: importedPath, passphrase: passphrase);
    expect(read.accounts.single.screenName, 'alice');

    await AccountVault().adoptFile(sourcePath: importedPath, libraryPath: libraryPath);

    expect(await AccountVault().exists(libraryPath), isTrue,
        reason: 'The next onboarding should find the imported backup without asking for the file again');
    expect(await AccountVault().lastSaved(libraryPath), isNotNull);
    final restored = await AccountVault().read(libraryPath: libraryPath, passphrase: passphrase);
    expect(restored.accounts.single.screenName, 'alice');
  });

  test('Should remove both the vault and its backup', () async {
    await addAccount('a', handle: 'alice');
    final vault = AccountVault();
    await vault.write(libraryPath: libraryPath, passphrase: passphrase);
    await vault.write(libraryPath: libraryPath, passphrase: passphrase);

    await vault.delete(libraryPath);

    expect(File(accountVaultPathFor(libraryPath)!).existsSync(), isFalse);
    expect(
        File(p.join(accountFolderPathFor(libraryPath)!, accountVaultBackupFileName)).existsSync(),
        isFalse);
  });
}
