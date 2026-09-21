import 'package:material_ui/material_ui.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/login_webview.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/settings/_account.dart';

/// Bottom sheet for switching the active account straight from the home app
/// bar: one tap and [accountsRevision] drops the loaded feeds, so the next
/// first page is fetched with the new login instead of mixing both accounts.
Future<void> showAccountSwitcher(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (_) => const _AccountSwitcher(),
  );
}

class _AccountSwitcher extends StatefulWidget {
  const _AccountSwitcher();

  @override
  State<_AccountSwitcher> createState() => _AccountSwitcherState();
}

class _AccountSwitcherState extends State<_AccountSwitcher> {
  final Future<List<Account>> _accounts = getAccounts();

  Future<void> _switch(Account account) async {
    if (!account.isActive) {
      await setActiveAccount(account.id);
    }
    if (mounted) Navigator.pop(context);
  }

  void _openManager() {
    final navigator = Navigator.of(context);
    Navigator.pop(context);
    navigator.push(MaterialPageRoute(builder: (_) => const SettingsAccountFragment()));
  }

  void _addAccount() {
    final navigator = Navigator.of(context);
    Navigator.pop(context);
    navigator.push(MaterialPageRoute(builder: (_) => const TwitterLoginWebview()));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FutureBuilder<List<Account>>(
        future: _accounts,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
          }

          final accounts = snapshot.data ?? [];
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (accounts.isEmpty)
                ListTile(
                  leading: const Icon(Icons.no_accounts_outlined),
                  title: Text(L10n.of(context).no_account_available_title),
                ),
              for (final account in accounts)
                ListTile(
                  leading: Icon(account.isActive ? Icons.radio_button_checked : Icons.account_circle_outlined),
                  title: Text(account.screenName ?? L10n.of(context).unknown_username),
                  selected: account.isActive,
                  onTap: () => _switch(account),
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.manage_accounts_outlined),
                title: Text(L10n.of(context).account),
                onTap: _openManager,
              ),
              ListTile(
                leading: const Icon(Icons.add),
                title: Text(L10n.of(context).add_account),
                onTap: _addAccount,
              ),
            ],
          );
        },
      ),
    );
  }
}
