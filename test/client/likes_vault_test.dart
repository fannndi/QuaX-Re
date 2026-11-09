import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quax/client/account_vault.dart';
import 'package:quax/client/likes_vault.dart';
import 'package:quax/client/vault_codec.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  const passphrase = 'correct horse battery';
  late Directory temp;
  late String libraryPath;
  late LikesVault vault;

  setUpAll(() {
    databaseName = 'quax_likes_vault_test.db';
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await deleteDatabase(databaseName);
    await Repository().migrate();
    temp = await Directory.systemTemp.createTemp('quax-likes-vault-');
    libraryPath = p.join(temp.path, 'QuaXLibrary');
    await Directory(libraryPath).create();
    vault = LikesVault(
      codec: const VaultCodec(iterations: 10000, maxEnvelopeLength: 48 * 1024 * 1024),
      tempDirectory: () async => temp,
    );
  });

  tearDown(() async {
    await deleteDatabase(databaseName);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> addAccount(String name,
      {String? localId, String? userId, String? handle}) async {
    final db = await Repository.writable();
    await db.insert(
        tableAccounts,
        Account(
          id: 'csrf-$name',
          authHeader: '{}',
          screenName: handle ?? name,
          userId: userId ?? '101',
          localId: localId ?? 'local-$name',
        ).toMap());
  }

  Future<void> seedLikes(String owner, int count, {String prefix = 't'}) async {
    final db = await Repository.writable();
    for (var i = 0; i < count; i++) {
      final at = DateTime.utc(2026, 1, 1).add(Duration(minutes: i)).toIso8601String();
      await db.insert(tableLikedTweet, {
        'id': '$prefix$i',
        'content': jsonEncode({'text': 'tweet $prefix$i'}),
        'user_id': 'author',
        columnLikedAt: at,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert(tableAccountLike, {
        columnAccountLocalId: owner,
        columnTweetId: '$prefix$i',
        columnLikedAt: at,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  test('Should write and read the local likes without plaintext', () async {
    await addAccount('a', userId: '101', handle: 'alice');
    await addAccount('b', userId: '102', handle: 'bob');
    await seedLikes('local-a', 3);
    await seedLikes('local-b', 2, prefix: 'b');

    final result = await vault.write(libraryPath: libraryPath, passphrase: passphrase);

    expect(result.likes, 5);
    final file = File(p.join(accountFolderPathFor(libraryPath)!, likesVaultFileName));
    expect(file.existsSync(), isTrue);
    final text = file.readAsStringSync();
    expect(text, isNot(contains('tweet t0')),
        reason: 'The post bodies are inside the encrypted blob, not beside it');
    expect(text, isNot(contains('alice')),
        reason: 'The account mapping is encrypted with the likes');

    final read = await vault.read(libraryPath: libraryPath, passphrase: passphrase);
    expect(read.likes, 5);
    expect(read.accounts, 2);
    expect(await vault.count(), 5);
  });

  test('Should restore the likes and keep the per-account owner', () async {
    await addAccount('a', userId: '101', handle: 'alice');
    await addAccount('b', userId: '102', handle: 'bob');
    await seedLikes('local-a', 3);
    await seedLikes('local-b', 2, prefix: 'b');
    await vault.write(libraryPath: libraryPath, passphrase: passphrase);

    final db = await Repository.writable();
    await db.delete(tableAccountLike);
    await db.delete(tableLikedTweet);

    final imported = await vault.import(libraryPath: libraryPath, passphrase: passphrase);

    expect(imported.restored, 5);
    expect(imported.skipped, 0);
    final rows = await Repository.read((db) => db.rawQuery('''
      SELECT $columnAccountLocalId AS owner, COUNT(*) AS c
      FROM $tableAccountLike GROUP BY $columnAccountLocalId ORDER BY owner
    '''));
    expect(rows.map((row) => row['owner']), ['local-a', 'local-b']);
    expect(rows.map((row) => row['c']), [3, 2]);
    expect(await vault.count(), 5);
  });

  test('Should not count likes that were already present as restored', () async {
    await addAccount('a', userId: '101', handle: 'alice');
    await seedLikes('local-a', 2);
    await vault.write(libraryPath: libraryPath, passphrase: passphrase);

    // Restore the same file a second time without clearing the database.
    final imported = await vault.import(libraryPath: libraryPath, passphrase: passphrase);

    expect(imported.restored, 0,
        reason: 'The rows are already there; reporting 2 would tell the reader that a second '
            'copy of their likes was written');
    expect(imported.skipped, 0,
        reason: 'A duplicate is not a malformed line; the file was fully readable');
    expect(await vault.count(), 2,
        reason: 'The duplicate restore must not add a second owner row');
  });

  test('Should delete the plaintext temp file when the gzip stream is corrupt', () async {
    await addAccount('a', userId: '101', handle: 'alice');
    final meta = utf8.encode(jsonEncode({
      'format': 'quax.likes',
      'version': 1,
      'like_count': 1,
      'accounts': [
        {'local_id': 'local-a', 'screen_name': 'alice', 'user_id': '101'}
      ],
    }));
    final container = <int>[
      (meta.length >> 24) & 0xff,
      (meta.length >> 16) & 0xff,
      (meta.length >> 8) & 0xff,
      meta.length & 0xff,
      ...meta,
      ...utf8.encode('not a gzip stream'),
    ];
    final envelope = await const VaultCodec(iterations: 10000).encryptBytes(
      passphrase: passphrase,
      kind: 'likes',
      bytes: container,
    );
    final folder = await ensureAccountFolder(libraryPath);
    await File(p.join(folder!, likesVaultFileName)).writeAsString(envelope);

    await expectLater(
      vault.import(libraryPath: libraryPath, passphrase: passphrase),
      throwsA(isA<VaultException>()
          .having((e) => e.failure, 'failure', VaultFailure.corrupt)),
      reason: 'A bad gzip stream must surface as a corrupt vault, not a raw FormatException',
    );
    final leftovers = temp
        .listSync()
        .whereType<File>()
        .where((file) => p.basename(file.path).startsWith('quax-likes-import-'))
        .toList();
    expect(leftovers, isEmpty,
        reason: 'The decoded likes are personal data and must not stay in the temp directory '
            'after a failed import');
  });

  test('Should map a restored account by user id when its local id changed', () async {
    await addAccount('a', userId: '101', handle: 'alice');
    await seedLikes('local-a', 2);
    await vault.write(libraryPath: libraryPath, passphrase: passphrase);

    final db = await Repository.writable();
    await db.update(tableAccounts, {columnLocalId: 'local-a-new'},
        where: 'id = ?', whereArgs: ['csrf-a']);
    await db.delete(tableAccountLike);
    await db.delete(tableLikedTweet);

    final imported = await vault.import(libraryPath: libraryPath, passphrase: passphrase);

    expect(imported.restored, 2);
    final owners = await Repository.read((db) =>
        db.query(tableAccountLike, columns: [columnAccountLocalId]));
    expect(owners.map((row) => row[columnAccountLocalId]), everyElement('local-a-new'),
        reason: 'The numeric user id is the stable bridge after a re-login changed the local id');
  });

  test('Should refuse to restore when none of the owners exist locally', () async {
    await addAccount('a', userId: '101', handle: 'alice');
    await seedLikes('local-a', 1);
    await vault.write(libraryPath: libraryPath, passphrase: passphrase);

    final db = await Repository.writable();
    await db.delete(tableAccounts);

    await expectLater(
        vault.import(libraryPath: libraryPath, passphrase: passphrase),
        throwsA(isA<LikesVaultNoAccounts>()),
        reason: 'Importing likes without their accounts would make them invisible');
  });

  test('Should import a file and adopt it beside QuaXLibrary', () async {
    await addAccount('a', userId: '101', handle: 'alice');
    await seedLikes('local-a', 2);
    await vault.write(libraryPath: libraryPath, passphrase: passphrase);
    final source = File(p.join(temp.path, 'from-pc.quaxvault'));
    await File(p.join(accountFolderPathFor(libraryPath)!, likesVaultFileName))
        .copy(source.path);
    await vault.delete(libraryPath);

    final db = await Repository.writable();
    await db.delete(tableAccountLike);
    await db.delete(tableLikedTweet);

    final imported = await vault.importFile(
      filePath: source.path,
      libraryPath: libraryPath,
      passphrase: passphrase,
    );

    expect(imported.restored, 2);
    expect(await vault.exists(libraryPath), isTrue,
        reason: 'The imported file is copied into QuaXAccount so the next restore finds it');
    expect(await vault.count(), 2);
  });

  test('Should fall back to .bak and change the passphrase', () async {
    await addAccount('a', userId: '101', handle: 'alice');
    await seedLikes('local-a', 1);
    await vault.write(libraryPath: libraryPath, passphrase: passphrase);
    await vault.write(libraryPath: libraryPath, passphrase: passphrase);

    final primary = File(p.join(accountFolderPathFor(libraryPath)!, likesVaultFileName));
    primary.writeAsStringSync('{not json');

    await vault.changePassphrase(
        libraryPath: libraryPath,
        oldPassphrase: passphrase,
        newPassphrase: 'new horse battery');

    await expectLater(
        vault.read(libraryPath: libraryPath, passphrase: passphrase),
        throwsA(isA<VaultException>()
            .having((e) => e.failure, 'failure', VaultFailure.wrongPassphrase)));
    final read = await vault.read(libraryPath: libraryPath, passphrase: 'new horse battery');
    expect(read.likes, 1);
    expect(
        File(p.join(accountFolderPathFor(libraryPath)!, likesVaultBackupFileName)).existsSync(),
        isFalse,
        reason: 'The .bak was encrypted with the old passphrase and must not keep it valid');
  });
}
