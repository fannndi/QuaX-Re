import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pref/pref.dart';
import 'package:quax/client/account_vault.dart';
import 'package:quax/client/vault_paths.dart';
import 'package:quax/constants.dart';

void main() {
  group('vaultRootPathFor()', () {
    test('Should prefer the folder pinned in preferences', () {
      final prefs = PrefServiceCache(cache: {
        optionLibraryPath: p.join('sdcard', 'Download', 'QuaXLibrary'),
        optionVaultRoot: p.join('sdcard', 'QuaX-Re'),
      });

      expect(vaultRootPathFor(prefs), p.join('sdcard', 'QuaX-Re'),
          reason: 'A library move must not take the encrypted account backups with it; the '
              'explicit folder is the one the reader (or the migration) chose');
    });

    test('Should fall back to the old sibling folder before the migration runs', () {
      final prefs = PrefServiceCache(cache: {
        optionLibraryPath: p.join('sdcard', 'Download', 'QuaXLibrary'),
      });

      expect(vaultRootPathFor(prefs), p.join('sdcard', 'Download'),
          reason: 'An install that has not run the new migration yet still stored QuaXAccount '
              'beside QuaXLibrary, so that parent has to keep working');
    });

    test('Should be empty when there is no library and no pinned folder', () {
      expect(vaultRootPathFor(PrefServiceCache()), isEmpty);
    });
  });

  test('accountFolderPathFor() should treat its argument as the vault root itself', () {
    expect(accountFolderPathFor(p.join('sdcard', 'QuaX-Re')),
        p.join('sdcard', 'QuaX-Re', accountFolderName),
        reason: 'The vault folder is no longer derived from the media library, so dirname() must '
            'not be applied a second time');
  });
}
