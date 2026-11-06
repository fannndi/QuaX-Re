import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:quax/client/account_vault.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/ui/errors.dart';
import 'package:quax/ui/passphrase_dialog.dart';
import 'package:quax/ui/vault_errors.dart';
import 'package:share_plus/share_plus.dart';

/// The account backup screen: create/update/restore the encrypted vault, share
/// it off-device before a ROM flash, or adopt a vault the reader picked from a
/// PC or cloud drive.
class AccountBackupScreen extends StatefulWidget {
  const AccountBackupScreen({super.key});

  @override
  State<AccountBackupScreen> createState() => _AccountBackupScreenState();
}

class _AccountBackupScreenState extends State<AccountBackupScreen> {
  final AccountVault _vault = AccountVault();
  late final BasePrefService _prefs;

  bool _initialized = false;
  bool _busy = false;
  bool _hasVault = false;
  bool _dirty = false;
  DateTime? _lastSaved;
  int _accountCount = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _prefs = PrefService.of(context, listen: false);
    _reload();
  }

  String get _libraryPath => _prefs.get<String>(optionLibraryPath) ?? '';

  Future<void> _reload() async {
    final path = _libraryPath;
    final hasVault = path.isNotEmpty && await _vault.exists(path);
    final lastSaved = path.isEmpty ? null : await _vault.lastSaved(path);
    final accounts = await getAccounts();
    if (!mounted) return;

    setState(() {
      _hasVault = hasVault;
      _lastSaved = lastSaved;
      _accountCount = accounts.length;
      _dirty = _prefs.get<bool>(optionAccountVaultDirty) ?? false;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reload();
  }

  Future<void> _createBackup() async {
    final l10n = L10n.of(context);
    if (_libraryPath.isEmpty) {
      showSnackBar(context, icon: '🙊', message: l10n.account_backup_no_library);
      return;
    }
    if (_accountCount == 0) {
      showSnackBar(context, icon: '🙊', message: l10n.account_backup_login_first);
      return;
    }

    final passphrase = await showVaultPassphraseDialog(context,
        confirm: true, title: _hasVault ? l10n.account_backup_update : l10n.account_backup_create);
    if (passphrase == null || !mounted) return;

    await _run(() async {
      final result = await _vault.write(libraryPath: _libraryPath, passphrase: passphrase);
      await _prefs.set<bool>(optionAccountVaultDirty, false);
      if (mounted) {
        showSnackBar(context,
            icon: '🔐', message: '${l10n.account_backup_saved} (${result.accounts})');
      }
    });
  }

  Future<void> _restore() async {
    final passphrase = await showVaultPassphraseDialog(context, confirm: false);
    if (passphrase == null || !mounted) return;

    AccountVaultReadResult result;
    try {
      result = await _vault.read(libraryPath: _libraryPath, passphrase: passphrase);
    } catch (error) {
      if (mounted) _showError(error);
      return;
    }
    if (!mounted) return;

    final replace = await _askReplace();
    if (replace == null || !mounted) return;

    await _run(() async {
      final imported = await importAccounts(result.accounts, replaceExisting: replace);
      await _prefs.set<bool>(optionAccountVaultDirty, false);
      _showRestored(result, imported);
    });
  }

  Future<void> _importFile() async {
    final l10n = L10n.of(context);
    if (_libraryPath.isEmpty) {
      showSnackBar(context, icon: '🙊', message: l10n.account_backup_no_library);
      return;
    }

    final files = await FilePicker.pickFiles(type: FileType.any);
    if (!mounted) return;
    final path = files.isEmpty ? null : files.single.path;
    if (path == null) {
      if (files.isNotEmpty) {
        showSnackBar(context, icon: '🙊', message: l10n.account_backup_invalid_file);
      }
      return;
    }

    final passphrase = await showVaultPassphraseDialog(context, confirm: false);
    if (passphrase == null || !mounted) return;

    AccountVaultReadResult result;
    try {
      result = await _vault.readFile(filePath: path, passphrase: passphrase);
    } catch (error) {
      if (mounted) _showError(error);
      return;
    }
    if (!mounted) return;

    final replace = await _askReplace();
    if (replace == null || !mounted) return;

    await _run(() async {
      final imported = await importAccounts(result.accounts, replaceExisting: replace);
      await _vault.adoptFile(sourcePath: path, libraryPath: _libraryPath);
      await _prefs.set<bool>(optionAccountVaultDirty, false);
      _showRestored(result, imported);
    });
  }

  Future<void> _share() async {
    final l10n = L10n.of(context);
    final path = accountVaultPathFor(_libraryPath);
    if (path == null || !await File(path).exists()) {
      if (mounted) showSnackBar(context, icon: '🙊', message: l10n.account_backup_missing);
      return;
    }
    if (!mounted) return;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.account_backup_share),
        content: Text(l10n.account_backup_share_warning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.share),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    await _run(() async {
      await SharePlus.instance.share(ShareParams(
        files: [XFile(path)],
        subject: l10n.account_backup_share_title,
      ));
    });
  }

  Future<void> _changePassphrase() async {
    final l10n = L10n.of(context);
    final oldPassphrase = await showVaultPassphraseDialog(context,
        confirm: false, title: l10n.account_backup_change_passphrase);
    if (oldPassphrase == null || !mounted) return;

    final newPassphrase = await showVaultPassphraseDialog(context,
        confirm: true, title: l10n.account_backup_change_passphrase);
    if (newPassphrase == null || !mounted) return;

    await _run(() async {
      await _vault.changePassphrase(
        libraryPath: _libraryPath,
        oldPassphrase: oldPassphrase,
        newPassphrase: newPassphrase,
      );
      await _prefs.set<bool>(optionAccountVaultDirty, false);
      if (mounted) {
        showSnackBar(context, icon: '🔐', message: l10n.account_backup_saved);
      }
    });
  }

  Future<void> _remove() async {
    final l10n = L10n.of(context);
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.account_backup_remove),
        content: Text(l10n.account_backup_remove_confirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.account_backup_remove),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    await _run(() async {
      await _vault.delete(_libraryPath);
      await _prefs.set<bool>(optionAccountVaultDirty, false);
    });
  }

  /// Returns null when the reader cancelled, false to keep the current
  /// sessions, and true to take the backup's sessions.
  Future<bool?> _askReplace() async {
    if (_accountCount == 0) return false;
    final l10n = L10n.of(context);
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.account_backup_replace),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.account_backup_replace_help),
            const SizedBox(height: 12),
            Text(l10n.account_backup_restore_warning,
                style: Theme.of(dialogContext).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.account_backup_keep),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.account_backup_use_backup),
          ),
        ],
      ),
    );
  }

  void _showRestored(AccountVaultReadResult result, AccountImportResult imported) {
    if (!mounted) return;
    showSnackBar(context,
        icon: '✅', message: accountRestoredMessage(L10n.of(context), result, imported));
  }

  void _showError(Object error) {
    showSnackBar(context, icon: '🙊', message: vaultErrorMessage(L10n.of(context), error));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.account_backup)),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _statusCard(l10n),
                const SizedBox(height: 12),
                Text(l10n.account_backup_description),
                if (_libraryPath.isEmpty) ...[
                  const SizedBox(height: 12),
                  Text(l10n.account_backup_no_library,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ] else ...[
                  const SizedBox(height: 16),
                  Text(l10n.account_backup_folder, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  _action(
                    icon: Icons.lock_outline,
                    title: _hasVault ? l10n.account_backup_update : l10n.account_backup_create,
                    onTap: _createBackup,
                  ),
                  if (_hasVault)
                    _action(
                      icon: Icons.restore,
                      title: l10n.account_backup_restore,
                      onTap: _restore,
                    ),
                  _action(
                    icon: Icons.file_open_outlined,
                    title: l10n.account_backup_import,
                    onTap: _importFile,
                  ),
                  if (_hasVault) ...[
                    _action(
                      icon: Icons.ios_share,
                      title: l10n.account_backup_share,
                      onTap: _share,
                    ),
                    _action(
                      icon: Icons.password,
                      title: l10n.account_backup_change_passphrase,
                      onTap: _changePassphrase,
                    ),
                    _action(
                      icon: Icons.delete_outline,
                      title: l10n.account_backup_remove,
                      onTap: _remove,
                      danger: true,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(l10n.account_backup_share_warning,
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusCard(L10n l10n) {
    final status = _libraryPath.isEmpty
        ? l10n.account_backup_no_library
        : !_hasVault
            ? l10n.account_backup_missing
            : _dirty
                ? l10n.account_backup_out_of_date
                : l10n.account_backup_up_to_date;
    final saved = _lastSaved;
    final subtitle = saved == null
        ? (_accountCount == 0 ? l10n.account_backup_none : l10n.account_backup_missing)
        : l10n.account_backup_last_saved(DateFormat.yMMMd().add_Hm().format(saved.toLocal()));
    final color = _hasVault && !_dirty
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;

    return Card(
      child: ListTile(
        leading: Icon(
          !_hasVault
              ? Icons.lock_outline
              : _dirty
                  ? Icons.warning_amber_outlined
                  : Icons.verified_user_outlined,
          color: color,
        ),
        title: Text(status),
        subtitle: Text(subtitle),
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String title,
    required Future<void> Function() onTap,
    bool danger = false,
  }) {
    final color = danger ? Theme.of(context).colorScheme.error : null;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title, style: color == null ? null : TextStyle(color: color)),
      enabled: !_busy,
      onTap: _busy ? null : onTap,
    );
  }
}
