import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:quax/client/account_vault.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/login_webview.dart';
import 'package:quax/constants.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/ui/errors.dart';
import 'package:quax/ui/passphrase_dialog.dart';
import 'package:quax/ui/vault_errors.dart';

/// The onboarding accounts step: restore the QuaXAccount vault, import a file,
/// or log in now. It deliberately does not block the wizard if the reader wants
/// to log in later.
class AccountSetupStep extends StatefulWidget {
  final String libraryPath;

  /// Test seams: the widget otherwise reads the database and the vault file.
  final Future<List<Account>> Function()? loadAccounts;
  final Future<bool> Function(String libraryPath)? vaultExists;

  const AccountSetupStep({
    super.key,
    required this.libraryPath,
    this.loadAccounts,
    this.vaultExists,
  });

  @override
  State<AccountSetupStep> createState() => _AccountSetupStepState();
}

class _AccountSetupStepState extends State<AccountSetupStep> {
  final AccountVault _vault = AccountVault();
  late final BasePrefService _prefs;

  bool _initialized = false;
  bool _loading = true;
  bool _busy = false;
  bool _hasVault = false;
  List<Account> _accounts = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _prefs = PrefService.of(context, listen: false);
    _reload();
  }

  @override
  void didUpdateWidget(AccountSetupStep oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.libraryPath != widget.libraryPath) _reload();
  }

  Future<void> _reload() async {
    final accounts = await (widget.loadAccounts ?? getAccounts)();
    final hasVault = widget.libraryPath.isNotEmpty &&
        await (widget.vaultExists != null
            ? widget.vaultExists!(widget.libraryPath)
            : _vault.exists(widget.libraryPath));
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _hasVault = hasVault;
      _loading = false;
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

  Future<void> _login() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const TwitterLoginWebview()));
    if (mounted) await _reload();
  }

  Future<void> _restore() async {
    final passphrase = await showVaultPassphraseDialog(context, confirm: false);
    if (passphrase == null || !mounted) return;

    AccountVaultReadResult result;
    try {
      result = await _vault.read(libraryPath: widget.libraryPath, passphrase: passphrase);
    } catch (error) {
      if (mounted) _showError(error);
      return;
    }
    if (!mounted) return;

    await _run(() async {
      final imported = await importAccounts(result.accounts);
      await _prefs.set<bool>(optionAccountVaultDirty, false);
      if (mounted) {
        showSnackBar(context,
            icon: '✅', message: accountRestoredMessage(L10n.of(context), result, imported));
      }
    });
  }

  Future<void> _importFile() async {
    final l10n = L10n.of(context);
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

    await _run(() async {
      final imported = await importAccounts(result.accounts);
      if (widget.libraryPath.isNotEmpty) {
        await _vault.adoptFile(sourcePath: path, libraryPath: widget.libraryPath);
      }
      await _prefs.set<bool>(optionAccountVaultDirty, false);
      if (mounted) {
        showSnackBar(context,
            icon: '✅', message: accountRestoredMessage(L10n.of(context), result, imported));
      }
    });
  }

  Future<void> _createBackup() async {
    final l10n = L10n.of(context);
    if (_accounts.isEmpty) {
      showSnackBar(context, icon: '🙊', message: l10n.account_backup_login_first);
      return;
    }

    final passphrase = await showVaultPassphraseDialog(context,
        confirm: true,
        title: _hasVault ? l10n.account_backup_update : l10n.account_backup_create);
    if (passphrase == null || !mounted) return;

    await _run(() async {
      await _vault.write(libraryPath: widget.libraryPath, passphrase: passphrase);
      await _prefs.set<bool>(optionAccountVaultDirty, false);
      if (mounted) {
        showSnackBar(context, icon: '🔐', message: l10n.account_backup_saved);
      }
    });
  }

  void _showError(Object error) {
    showSnackBar(context, icon: '🙊', message: vaultErrorMessage(L10n.of(context), error));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    if (_loading) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_busy) const LinearProgressIndicator(),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(_accounts.isEmpty
                      ? Icons.person_off_outlined
                      : Icons.people_outline),
                  title: Text(_accounts.isEmpty
                      ? l10n.account_backup_none
                      : l10n.setup_accounts_have(_accounts.length)),
                ),
                for (final account in _accounts)
                  ListTile(
                    dense: true,
                    leading: Icon(account.isActive
                        ? Icons.radio_button_checked
                        : Icons.account_circle_outlined),
                    title: Text('@${account.screenName ?? '?'}'),
                  ),
              ],
            ),
          ),
          if (_hasVault) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.lock_outline),
                      title: Text(l10n.setup_accounts_restore_title),
                      subtitle: Text(l10n.setup_accounts_restore_body),
                    ),
                    FilledButton.icon(
                      onPressed: _busy ? null : _restore,
                      icon: const Icon(Icons.restore),
                      label: Text(l10n.account_backup_restore),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _login,
                icon: const Icon(Icons.login),
                label: Text(l10n.setup_accounts_login),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _importFile,
                icon: const Icon(Icons.file_open_outlined),
                label: Text(l10n.setup_accounts_import),
              ),
              if (_accounts.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _createBackup,
                  icon: const Icon(Icons.lock_outline),
                  label: Text(
                      _hasVault ? l10n.account_backup_update : l10n.account_backup_create),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(l10n.setup_accounts_skip,
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
