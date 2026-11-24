import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quax/client/account_vault.dart';
import 'package:quax/client/likes_vault.dart';
import 'package:quax/client/vault_codec.dart';
import 'package:quax/client/vault_paths.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/settings/account_backup.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FailingLikesVault extends LikesVault {
  _FailingLikesVault({required super.codec});

  @override
  Future<String> preparePassphraseChange({
    required String vaultRoot,
    required String oldPassphrase,
    required String newPassphrase,
  }) async => throw StateError('injected likes encryption failure');
}

void main() {
  const oldPassphrase = 'correct horse battery';
  const newPassphrase = 'another horse battery';
  late Directory temp;
  late String vaultRoot;
  late AccountVault accounts;
  late LikesVault likes;

  setUpAll(() {
    databaseName = 'quax_backup_rotation_test.db';
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await deleteDatabase(databaseName);
    await Repository().migrate();
    temp = await Directory.systemTemp.createTemp('quax-backup-rotation-');
    vaultRoot = p.join(temp.path, 'backups');
    await Directory(vaultRoot).create();
    const codec = VaultCodec(
      iterations: 10000,
      maxEnvelopeLength: 48 * 1024 * 1024,
    );
    accounts = AccountVault(codec: codec);
    likes = LikesVault(codec: codec, tempDirectory: () async => temp);
    final db = await Repository.writable();
    await db.insert(
      tableAccounts,
      Account(
        id: 'csrf-a',
        authHeader: '{"Cookie":"auth_token=token;ct0=csrf-a"}',
        screenName: 'alice',
        userId: '101',
        localId: 'local-a',
      ).toMap(),
    );
    await db.insert(tableLikedTweet, {'id': 't1', 'content': '{}'});
    await db.insert(tableAccountLike, {
      columnAccountLocalId: 'local-a',
      columnTweetId: 't1',
    });
  });

  tearDown(() async {
    await deleteDatabase(databaseName);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('Should rotate both vaults and remove old-passphrase backups only after success', () async {
    await accounts.write(vaultRoot: vaultRoot, passphrase: oldPassphrase);
    await accounts.write(vaultRoot: vaultRoot, passphrase: oldPassphrase);
    await likes.write(vaultRoot: vaultRoot, passphrase: oldPassphrase);
    await likes.write(vaultRoot: vaultRoot, passphrase: oldPassphrase);

    await rotateVaultPassphrases(
      accountVault: accounts,
      likesVault: likes,
      vaultRoot: vaultRoot,
      oldPassphrase: oldPassphrase,
      newPassphrase: newPassphrase,
    );

    expect(
      (await accounts.read(
        vaultRoot: vaultRoot,
        passphrase: newPassphrase,
      )).accounts,
      hasLength(1),
      reason: 'The account primary accepts the new shared passphrase',
    );
    expect(
      (await likes.read(vaultRoot: vaultRoot, passphrase: newPassphrase)).likes,
      1,
      reason: 'The likes primary accepts the same new passphrase',
    );
    await expectLater(
      accounts.read(vaultRoot: vaultRoot, passphrase: oldPassphrase),
      throwsA(isA<VaultException>()),
      reason: 'The old account passphrase no longer opens any copy',
    );
    await expectLater(
      likes.read(vaultRoot: vaultRoot, passphrase: oldPassphrase),
      throwsA(isA<VaultException>()),
      reason: 'The old likes passphrase no longer opens any copy',
    );
    final folder = accountFolderPathFor(vaultRoot)!;
    expect(
      await File(p.join(folder, accountVaultBackupFileName)).exists(),
      isFalse,
      reason: 'The old-passphrase account backup is removed after both commits',
    );
    expect(
      await File(p.join(folder, likesVaultBackupFileName)).exists(),
      isFalse,
      reason: 'The old-passphrase likes backup is removed after both commits',
    );
  });

  test('Should keep an imported likes backup dirty when the file is older', () {
    expect(
      savedLikesSnapshotAfterImport(
        liveSnapshot: '4:2026-11-24:new-mapping',
        importedSnapshot: '2:2026-01-01:old-mapping',
      ),
      isEmpty,
      reason: 'The merged database has likes or owner mappings that the adopted file does not',
    );
    expect(
      savedLikesSnapshotAfterImport(
        liveSnapshot: '2:2026-01-01:same-mapping',
        importedSnapshot: '2:2026-01-01:same-mapping',
      ),
      '2:2026-01-01:same-mapping',
      reason: 'An exact match is the only case where import can leave the backup clean',
    );
  });

  test('Should reject a split passphrase before an account backup update', () async {
    await accounts.write(vaultRoot: vaultRoot, passphrase: oldPassphrase);
    await likes.write(vaultRoot: vaultRoot, passphrase: oldPassphrase);
    final primary = File(accountVaultPathFor(vaultRoot)!);
    final before = await primary.readAsString();

    await expectLater(
      verifyAccountBackupPassphrase(
        accountVault: accounts,
        hasLikesVault: true,
        vaultRoot: vaultRoot,
        passphrase: 'wrong horse battery',
      ),
      throwsA(isA<VaultException>()),
      reason:
          'A likes vault requires the entered phrase to open the account vault',
    );

    expect(
      await primary.readAsString(),
      before,
      reason: 'A failed verification must not replace the account vault or split the pair',
    );
  });

  test(
    'Should preserve the caller dirty state after a passphrase change',
    () async {
      await accounts.write(vaultRoot: vaultRoot, passphrase: oldPassphrase);
      await likes.write(vaultRoot: vaultRoot, passphrase: oldPassphrase);
      bool? savedDirty;

      await changeAccountBackupPassphrase(
        accountVault: accounts,
        likesVault: likes,
        vaultRoot: vaultRoot,
        oldPassphrase: oldPassphrase,
        newPassphrase: newPassphrase,
        wasDirty: true,
        saveDirty: (dirty) async => savedDirty = dirty,
      );

      expect(
        savedDirty,
        isTrue,
        reason:
            'Changing encryption does not update the account list, so an out-of-date '
            'backup must remain out of date',
      );
    },
  );

  test('Should leave both vaults untouched when preparing the second envelope fails', () async {
    await accounts.write(vaultRoot: vaultRoot, passphrase: oldPassphrase);
    await accounts.write(vaultRoot: vaultRoot, passphrase: oldPassphrase);
    await likes.write(vaultRoot: vaultRoot, passphrase: oldPassphrase);
    await likes.write(vaultRoot: vaultRoot, passphrase: oldPassphrase);
    final folder = accountFolderPathFor(vaultRoot)!;
    final accountPrimary = File(p.join(folder, accountVaultFileName));
    final likesPrimary = File(p.join(folder, likesVaultFileName));
    final beforeAccounts = await accountPrimary.readAsString();
    final beforeLikes = await likesPrimary.readAsString();

    await expectLater(
      rotateVaultPassphrases(
        accountVault: accounts,
        likesVault: _FailingLikesVault(
          codec: const VaultCodec(iterations: 10000),
        ),
        vaultRoot: vaultRoot,
        oldPassphrase: oldPassphrase,
        newPassphrase: newPassphrase,
      ),
      throwsStateError,
      reason:
          'The injected likes preparation failure must abort the pair rotation',
    );

    expect(
      await accountPrimary.readAsString(),
      beforeAccounts,
      reason:
          'The account envelope must not be published while the likes envelope is still '
          'being prepared',
    );
    expect(
      await likesPrimary.readAsString(),
      beforeLikes,
      reason: 'The likes primary is never staged or committed before preparation finishes',
    );
    expect(
      (await accounts.read(
        vaultRoot: vaultRoot,
        passphrase: oldPassphrase,
      )).accounts,
      hasLength(1),
      reason: 'The account vault remains readable with the old passphrase',
    );
    expect(
      (await likes.read(vaultRoot: vaultRoot, passphrase: oldPassphrase)).likes,
      1,
      reason: 'The likes vault remains readable with the old passphrase',
    );
  });
}
