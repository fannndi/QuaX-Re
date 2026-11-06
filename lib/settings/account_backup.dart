import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:quax/client/account_vault.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/likes_vault.dart';
import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/likes/liked_tweet_model.dart';
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
  final LikesVault _likesVault = LikesVault();
  late final BasePrefService _prefs;

  bool _initialized = false;
  bool _busy = false;
  bool _hasVault = false;
  bool _dirty = false;
  bool _hasLikesVault = false;
  bool _likesDirty = false;
  DateTime? _lastSaved;
  DateTime? _likesSaved;
  int _accountCount = 0;
  int _localLikeCount = 0;

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
    final hasLikesVault = path.isNotEmpty && await _likesVault.exists(path);
    final likesSaved = path.isEmpty ? null : await _likesVault.lastSaved(path);
    final accounts = await getAccounts();

    var localLikes = 0;
    var likesSnapshot = '0:';
    if (path.isNotEmpty) {
      localLikes = await _likesVault.count();
      likesSnapshot = await _likesVault.snapshot();
    }
    final savedLikesSnapshot = _prefs.get<String>(optionLikesVaultSnapshot);
    if (!mounted) return;

    setState(() {
      _hasVault = hasVault;
      _lastSaved = lastSaved;
      _accountCount = accounts.length;
      _dirty = _prefs.get<bool>(optionAccountVaultDirty) ?? false;
      _hasLikesVault = hasLikesVault;
      _likesSaved = likesSaved;
      _localLikeCount = localLikes;
      _likesDirty = hasLikesVault &&
          (savedLikesSnapshot == null || savedLikesSnapshot != likesSnapshot);
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
    if (!await _confirm(l10n.account_backup_share, l10n.account_backup_share_warning, l10n.share)) {
      return;
    }
    if (!mounted) return;

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
      if (_hasLikesVault) {
        // Both files are meant to share one passphrase. The account vault is
        // already on the new one, so a failure here leaves the likes backup
        // readable with the old phrase until it is recreated.
        await _likesVault.changePassphrase(
          libraryPath: _libraryPath,
          oldPassphrase: oldPassphrase,
          newPassphrase: newPassphrase,
        );
      }
      await _prefs.set<bool>(optionAccountVaultDirty, false);
      if (mounted) {
        showSnackBar(context, icon: '🔐', message: l10n.account_backup_saved);
      }
    });
  }

  Future<void> _remove() async {
    final l10n = L10n.of(context);
    if (!await _confirm(
        l10n.account_backup_remove, l10n.account_backup_remove_confirm, l10n.account_backup_remove)) {
      return;
    }
    if (!mounted) return;

    await _run(() async {
      await _vault.delete(_libraryPath);
      await _prefs.set<bool>(optionAccountVaultDirty, false);
    });
  }

  Future<bool> _confirm(String title, String message, String action) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(L10n.of(dialogContext).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _createLikesBackup() async {
    final l10n = L10n.of(context);
    if (!_hasVault) {
      showSnackBar(context, icon: '🙊', message: l10n.likes_backup_needs_account_vault);
      return;
    }
    if (_localLikeCount == 0) {
      showSnackBar(context, icon: '🙊', message: l10n.likes_backup_no_likes);
      return;
    }

    final passphrase = await showVaultPassphraseDialog(context,
        confirm: false,
        title: _hasLikesVault ? l10n.likes_backup_update : l10n.likes_backup_create);
    if (passphrase == null || !mounted) return;

    // Both files share one passphrase; verifying it against the account vault
    // now keeps a different likes passphrase from making a later change fail
    // halfway through.
    try {
      await _vault.read(libraryPath: _libraryPath, passphrase: passphrase);
    } catch (error) {
      if (mounted) _showError(error);
      return;
    }
    if (!mounted) return;

    await _run(() async {
      final result = await _likesVault.write(libraryPath: _libraryPath, passphrase: passphrase);
      await _prefs.set<String>(optionLikesVaultSnapshot, await _likesVault.snapshot());
      if (mounted) {
        showSnackBar(context,
            icon: '🔐', message: '${l10n.likes_backup_saved} (${result.likes})');
      }
    });
  }

  Future<void> _restoreLikes() async {
    final l10n = L10n.of(context);
    final passphrase =
        await showVaultPassphraseDialog(context, confirm: false, title: l10n.likes_backup_restore);
    if (passphrase == null || !mounted) return;

    await _run(() async {
      final result = await _likesVault.import(libraryPath: _libraryPath, passphrase: passphrase);
      if (!mounted) return;
      await context.read<LikedTweetModel>().refreshLikedTweets();
      if (mounted) _showLikesRestored(result);
    });
  }

  Future<void> _importLikesFile() async {
    final l10n = L10n.of(context);
    if (!_hasVault) {
      showSnackBar(context, icon: '🙊', message: l10n.likes_backup_needs_account_vault);
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

    final passphrase = await showVaultPassphraseDialog(context,
        confirm: false, title: l10n.likes_backup_import);
    if (passphrase == null || !mounted) return;

    await _run(() async {
      final result = await _likesVault.importFile(
        filePath: path,
        libraryPath: _libraryPath,
        passphrase: passphrase,
      );
      await _prefs.set<String>(optionLikesVaultSnapshot, await _likesVault.snapshot());
      if (!mounted) return;
      await context.read<LikedTweetModel>().refreshLikedTweets();
      if (mounted) _showLikesRestored(result);
    });
  }

  Future<void> _shareLikes() async {
    final l10n = L10n.of(context);
    final path = likesVaultPathFor(_libraryPath);
    if (path == null || !await File(path).exists()) {
      if (mounted) showSnackBar(context, icon: '🙊', message: l10n.likes_backup_file_missing);
      return;
    }
    if (!await _confirm(l10n.likes_backup_share, l10n.account_backup_share_warning, l10n.share)) {
      return;
    }
    if (!mounted) return;

    await _run(() async {
      await SharePlus.instance.share(ShareParams(
        files: [XFile(path)],
        subject: l10n.likes_backup_share_title,
      ));
    });
  }

  Future<void> _removeLikes() async {
    final l10n = L10n.of(context);
    if (!await _confirm(
        l10n.likes_backup_remove, l10n.likes_backup_remove_confirm, l10n.likes_backup_remove)) {
      return;
    }
    if (!mounted) return;

    await _run(() async {
      await _likesVault.delete(_libraryPath);
      await _prefs.set<String>(optionLikesVaultSnapshot, '');
    });
  }

  void _showLikesRestored(LikesVaultImportResult result) {
    if (!mounted) return;
    final l10n = L10n.of(context);
    final message = result.restored == 0
        ? l10n.likes_backup_none_restored
        : result.skipped > 0
            ? l10n.likes_backup_restored_partial(result.restored, result.skipped)
            : l10n.likes_backup_restored(result.restored);
    showSnackBar(context, icon: '✅', message: message);
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
                  const Divider(),
                  Text(l10n.likes_backup, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(l10n.likes_backup_description,
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  if (!_hasVault)
                    Text(l10n.likes_backup_needs_account_vault,
                        style: TextStyle(color: Theme.of(context).colorScheme.error))
                  else ...[
                    _likesStatusCard(l10n),
                    _action(
                      icon: Icons.favorite_border,
                      title: _hasLikesVault
                          ? l10n.likes_backup_update
                          : l10n.likes_backup_create,
                      onTap: _createLikesBackup,
                    ),
                    if (_hasLikesVault)
                      _action(
                        icon: Icons.restore,
                        title: l10n.likes_backup_restore,
                        onTap: _restoreLikes,
                      ),
                    _action(
                      icon: Icons.file_open_outlined,
                      title: l10n.likes_backup_import,
                      onTap: _importLikesFile,
                    ),
                    if (_hasLikesVault) ...[
                      _action(
                        icon: Icons.ios_share,
                        title: l10n.likes_backup_share,
                        onTap: _shareLikes,
                      ),
                      _action(
                        icon: Icons.delete_outline,
                        title: l10n.likes_backup_remove,
                        onTap: _removeLikes,
                        danger: true,
                      ),
                    ],
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

  Widget _likesStatusCard(L10n l10n) {
    final status = !_hasLikesVault
        ? l10n.likes_backup_missing
        : _likesDirty
            ? l10n.likes_backup_out_of_date
            : l10n.likes_backup_up_to_date;
    final saved = _likesSaved;
    final subtitle = saved == null
        ? l10n.likes_backup_count(_localLikeCount)
        : '${l10n.account_backup_last_saved(DateFormat.yMMMd().add_Hm().format(saved.toLocal()))}'
            ' · ${l10n.likes_backup_count(_localLikeCount)}';
    final color = _hasLikesVault && !_likesDirty
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;

    return Card(
      child: ListTile(
        leading: Icon(
          !_hasLikesVault
              ? Icons.favorite_border
              : _likesDirty
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
