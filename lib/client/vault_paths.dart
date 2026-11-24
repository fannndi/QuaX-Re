import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';
import 'package:quax/utils/atomic_file.dart';

/// The shared-storage folder that holds `QuaXAccount`.
///
/// Before hidden storage existed the vault was a sibling of `QuaXLibrary`, so
/// the library parent was the answer. A hidden library now lives under
/// `Android/data`, which the system deletes on uninstall; keeping the vault
/// there would defeat its purpose. The explicit preference wins, and the old
/// derivation stays as a fallback for an install whose migration has not run
/// yet.
String vaultRootPathFor(BasePrefService prefs) {
  final explicit = prefs.get<String>(optionVaultRoot);
  if (explicit != null && explicit.isNotEmpty) return explicit;

  final library = prefs.get<String>(optionLibraryPath) ?? '';
  if (library.isEmpty) return '';
  final parent = p.dirname(library);
  return parent == '.' ? '' : parent;
}

class VaultReplacement {
  final File primary;
  final File backup;
  final String envelope;
  final Future<bool> Function() validatePrimary;

  const VaultReplacement({
    required this.primary,
    required this.backup,
    required this.envelope,
    required this.validatePrimary,
  });
}

abstract interface class VaultPassphraseSource {
  Future<String> preparePassphraseChange({
    required String vaultRoot,
    required String oldPassphrase,
    required String newPassphrase,
  });

  Future<bool> canBackupPrimary({
    required String vaultRoot,
    required String passphrase,
  });

  VaultReplacement replacementFor({
    required String vaultRoot,
    required String envelope,
    required String passphrase,
  });
}

/// Prepares both passphrase envelopes before staging either one. The shared
/// file helper keeps both old backups until every primary has committed.
Future<void> rotateVaultPassphrases({
  required VaultPassphraseSource accountVault,
  VaultPassphraseSource? likesVault,
  required String vaultRoot,
  required String oldPassphrase,
  required String newPassphrase,
  Future<void> Function(int index)? beforeCommit,
}) async {
  final accountEnvelope = await accountVault.preparePassphraseChange(
    vaultRoot: vaultRoot,
    oldPassphrase: oldPassphrase,
    newPassphrase: newPassphrase,
  );
  final likesSource = likesVault;
  final likesEnvelope = likesSource == null
      ? null
      : await likesSource.preparePassphraseChange(
          vaultRoot: vaultRoot,
          oldPassphrase: oldPassphrase,
          newPassphrase: newPassphrase,
        );
  await replaceVaultFiles([
    accountVault.replacementFor(
      vaultRoot: vaultRoot,
      envelope: accountEnvelope,
      passphrase: oldPassphrase,
    ),
    if (likesSource != null)
      likesSource.replacementFor(
        vaultRoot: vaultRoot,
        envelope: likesEnvelope!,
        passphrase: oldPassphrase,
      ),
  ], beforeCommit: beforeCommit);
}

/// Stages every envelope, promotes only validated primaries to `.bak`, then
/// commits all primaries before removing the old-passphrase backups.
///
/// A staging or validation failure leaves every primary untouched. A later
/// commit failure can leave an earlier primary on the new passphrase, but its
/// old backup remains available so a retry can recover and finish the pair.
Future<void> replaceVaultFiles(
  List<VaultReplacement> replacements, {
  Future<void> Function(int index)? beforeCommit,
  bool removeBackups = true,
}) async {
  final staged = <({File file, VaultReplacement replacement})>[];
  try {
    for (final replacement in replacements) {
      staged.add((
        file: await stageAtomically(replacement.primary, replacement.envelope),
        replacement: replacement,
      ));
    }

    for (final entry in staged) {
      final replacement = entry.replacement;
      if (!await replacement.primary.exists() ||
          !await replacement.validatePrimary()) {
        continue;
      }
      try {
        await replacement.primary.copy(replacement.backup.path);
      } catch (_) {
        // An existing good backup is still better than replacing a corrupt
        // primary. Without any backup, fail before committing the new file.
        if (!await replacement.backup.exists()) rethrow;
      }
    }

    for (var index = 0; index < staged.length; index++) {
      await beforeCommit?.call(index);
    }
    for (final entry in staged) {
      await commitStagedAtomically(entry.file, entry.replacement.primary);
    }
    if (removeBackups) {
      for (final replacement in replacements) {
        if (await replacement.backup.exists()) {
          await replacement.backup.delete();
        }
      }
    }
  } finally {
    for (final entry in staged) {
      try {
        if (await entry.file.exists()) await entry.file.delete();
      } catch (_) {
        // Never hide the original staging/commit failure.
      }
    }
  }
}
