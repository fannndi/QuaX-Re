import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quax/client/vault_paths.dart';

void main() {
  Future<Directory> tempDirectory() async {
    final dir = await Directory.systemTemp.createTemp('quax-vault-rotation-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    return dir;
  }

  test('Should stage every envelope before replacing any primary', () async {
    final dir = await tempDirectory();
    final first = File(p.join(dir.path, 'first'));
    final second = File(p.join(dir.path, 'second'));
    await first.writeAsString('old first');
    await second.writeAsString('old second');
    var secondValidated = false;

    await replaceVaultFiles([
      VaultReplacement(
        primary: first,
        backup: File('${first.path}.bak'),
        envelope: 'new first',
        validatePrimary: () async {
          expect(
            secondValidated,
            isFalse,
            reason: 'All validation and backup work must finish before the first commit',
          );
          return true;
        },
      ),
      VaultReplacement(
        primary: second,
        backup: File('${second.path}.bak'),
        envelope: 'new second',
        validatePrimary: () async {
          secondValidated = true;
          expect(
            await first.readAsString(),
            'old first',
            reason: 'Even the second validator must run before the first primary changes',
          );
          return true;
        },
      ),
    ]);

    expect(
      await first.readAsString(),
      'new first',
      reason:
          'The first staged envelope commits after all stages and validations',
    );
    expect(
      await second.readAsString(),
      'new second',
      reason: 'The second staged envelope commits in the same pair',
    );
    expect(
      await File('${first.path}.bak').exists(),
      isFalse,
      reason: 'Old-passphrase backups are removed only after both primaries succeeded',
    );
    expect(
      await File('${second.path}.bak').exists(),
      isFalse,
      reason: 'Neither old-passphrase backup survives a successful pair',
    );
  });

  test(
    'Should keep every primary and backup when staging the second file fails',
    () async {
      final dir = await tempDirectory();
      final first = File(p.join(dir.path, 'first'));
      await first.writeAsString('old first');
      final blockedParent = File(p.join(dir.path, 'not-a-directory'));
      await blockedParent.writeAsString('occupied');

      await expectLater(
        replaceVaultFiles([
          VaultReplacement(
            primary: first,
            backup: File('${first.path}.bak'),
            envelope: 'new first',
            validatePrimary: () async => true,
          ),
          VaultReplacement(
            primary: File(p.join(blockedParent.path, 'second')),
            backup: File(p.join(blockedParent.path, 'second.bak')),
            envelope: 'new second',
            validatePrimary: () async => true,
          ),
        ]),
        throwsA(isA<FileSystemException>()),
        reason: 'The blocked second stage must surface its filesystem failure',
      );

      expect(
        await first.readAsString(),
        'old first',
        reason: 'A failed stage must not publish the first envelope',
      );
      expect(
        await File('${first.path}.bak').exists(),
        isFalse,
        reason: 'No backup promotion starts until every envelope has staged',
      );
      expect(
        await dir
            .list()
            .where((entity) => entity.path.endsWith('.tmp'))
            .toList(),
        isEmpty,
        reason: 'The staged first envelope contains secrets and must be removed on failure',
      );
    },
  );

  test('Should retain old backups when a later commit fails', () async {
    final dir = await tempDirectory();
    final first = File(p.join(dir.path, 'first'));
    final second = Directory(p.join(dir.path, 'second'));
    await first.writeAsString('old first');
    await second.create();

    await expectLater(
      replaceVaultFiles([
        VaultReplacement(
          primary: first,
          backup: File('${first.path}.bak'),
          envelope: 'new first',
          validatePrimary: () async => true,
        ),
        VaultReplacement(
          primary: File(second.path),
          backup: File('${second.path}.bak'),
          envelope: 'new second',
          validatePrimary: () async => false,
        ),
      ]),
      throwsA(isA<FileSystemException>()),
      reason: 'A directory cannot be replaced by the staged second file',
    );

    expect(
      await File('${first.path}.bak').readAsString(),
      'old first',
      reason:
          'The first new primary must keep its old-passphrase rollback until the pair '
          'has fully committed',
    );
    expect(
      await dir.list().where((entity) => entity.path.endsWith('.tmp')).toList(),
      isEmpty,
      reason: 'The failed second commit must clean its staged envelope',
    );
  });

  test('Should not copy a corrupt primary over a good backup', () async {
    final dir = await tempDirectory();
    final primary = File(p.join(dir.path, 'vault'));
    final backup = File('${primary.path}.bak');
    await primary.writeAsString('corrupt');
    await backup.writeAsString('good backup');

    await expectLater(
      replaceVaultFiles(
        [
          VaultReplacement(
            primary: primary,
            backup: backup,
            envelope: 'new vault',
            validatePrimary: () async => false,
          ),
        ],
        beforeCommit: (_) async => throw StateError('injected commit failure'),
      ),
      throwsStateError,
      reason: 'The injected pre-commit failure lets the test inspect backup promotion',
    );

    expect(
      await backup.readAsString(),
      'good backup',
      reason: 'A validator rejection must preserve the last known-good backup',
    );
  });
}
