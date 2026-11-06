import 'package:quax/client/account_vault.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/vault_codec.dart';
import 'package:quax/generated/l10n.dart';

/// Maps the vault failures to the sentence the reader sees. Shared by the
/// onboarding step and the backup screen so the two cannot drift.
String vaultErrorMessage(L10n l10n, Object error) => switch (error) {
      VaultException(failure: VaultFailure.wrongPassphrase) => l10n.account_backup_passphrase_wrong,
      VaultException(failure: VaultFailure.weakPassphrase) => l10n.account_backup_passphrase_hint,
      VaultException(failure: VaultFailure.corrupt) => l10n.account_backup_corrupt,
      VaultException(failure: VaultFailure.unsupportedVersion) => l10n.account_backup_unsupported,
      VaultException(failure: VaultFailure.tooLarge) => l10n.account_backup_too_large,
      AccountVaultNotFound() => l10n.account_backup_file_missing,
      _ => '$error',
    };

/// "Restored N accounts" plus the count of entries the parser had to skip and
/// how many local sessions were kept instead of overwritten.
String accountRestoredMessage(
    L10n l10n, AccountVaultReadResult read, AccountImportResult imported) {
  final message = read.invalid > 0
      ? l10n.account_backup_restored_partial(imported.total, read.invalid)
      : l10n.account_backup_restored(imported.total);
  final kept = imported.kept > 0 ? ' ${l10n.account_backup_kept}.' : '';
  return '$message$kept';
}
