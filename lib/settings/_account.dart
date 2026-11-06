import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/client.dart';
import 'package:quax/client/client_regular_account.dart';
import 'package:quax/client/login_webview.dart';
import 'package:quax/constants.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/profile/_likes.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/settings/account_backup.dart';

/// The accounts screen: add an account, delete one (swipe), pick the one the
/// app talks to — and jump into your own profile or your likes.
class SettingsAccountFragment extends StatefulWidget {
  const SettingsAccountFragment({super.key});

  @override
  State<SettingsAccountFragment> createState() => _SettingsAccountFragment();
}

class _SettingsAccountFragment extends State<SettingsAccountFragment> {
  late Future<List<Account>> _accountsFuture;

  @override
  void initState() {
    super.initState();
    _accountsFuture = getAccounts();
  }

  void _reloadAccounts() {
    if (!mounted) return;
    setState(() => _accountsFuture = getAccounts());
  }

  Future<void> _activate(Account account) async {
    await setActiveAccount(account.id);
    _reloadAccounts();
  }

  void _openProfile(Account account) {
    final screenName = account.screenName;
    if (screenName == null) return;
    Navigator.pushNamed(context, routeProfile,
        arguments: ProfileScreenArguments.fromScreenName(screenName, 0));
  }

  /// Opens the X likes timeline of the active account (private data: X answers
  /// this only for the requesting account itself).
  Future<void> _openMyLikes() async {
    final active = await getActiveAccount();
    final screenName = active?.screenName;
    if (screenName == null || !mounted) return;

    final profile = await Twitter.getProfileByScreenName(screenName);
    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => ProfileLikesScreen(user: profile.user)));
  }

  @override
  Widget build(BuildContext context) {
    var model = XRegularAccount();
    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.current.account),
        actions: [
          IconButton(
              icon: const Icon(Icons.favorite_border),
              tooltip: L10n.current.favorites,
              onPressed: _openMyLikes),
          IconButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TwitterLoginWebview())),
              icon: const Icon(Icons.add))
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: FutureBuilder(
                future: _accountsFuture,
                builder: (BuildContext listContext, AsyncSnapshot snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const LinearProgressIndicator();
                  }

                  if (snapshot.hasError) {
                    return Center(
                      child: TextButton(
                        onPressed: _reloadAccounts,
                        child: Text(L10n.of(context).retry),
                      ),
                    );
                  }

                  final List<Account> data = snapshot.data ?? const <Account>[];
                  if (data.isEmpty) {
                    return const SizedBox.shrink();
                  }

                  return ListView.builder(
                      itemCount: data.length,
                      itemBuilder: (BuildContext itemContext, int index) {
                        final account = data[index];
                        return Dismissible(
                            key: ValueKey(account.id),
                            confirmDismiss: (DismissDirection direction) async {
                              return await showDialog<bool>(
                                    context: context,
                                    builder: (dialogContext) => AlertDialog(
                                      title: Text(L10n.of(dialogContext).are_you_sure),
                                      content: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(L10n.of(dialogContext).delete),
                                          const SizedBox(height: 8),
                                          Text(L10n.of(dialogContext).account_delete_local_likes),
                                        ],
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(dialogContext, false),
                                          child: Text(L10n.of(dialogContext).cancel),
                                        ),
                                        TextButton(
                                          onPressed: () => Navigator.pop(dialogContext, true),
                                          child: Text(L10n.of(dialogContext).delete),
                                        ),
                                      ],
                                    ),
                                  ) ??
                                  false;
                            },
                            onDismissed: (DismissDirection direction) async {
                              await model.deleteAccount(account.id);
                              if (context.mounted) {
                                await PrefService.of(context, listen: false)
                                    .set<bool>(optionAccountVaultDirty, true);
                              }
                              _reloadAccounts();
                            },
                            child: Card(
                                child: ListTile(
                              title: Text(account.screenName ?? L10n.of(context).unknown_username),
                              leading: Icon(account.isActive
                                  ? Icons.radio_button_checked
                                  : Icons.account_circle),
                              trailing: IconButton(
                                icon: const Icon(Icons.person_outline),
                                onPressed: () => _openProfile(account),
                              ),
                              selected: account.isActive,
                              onTap: account.isActive ? null : () => _activate(account),
                            )));
                      });
                }),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: Text(L10n.of(context).account_backup),
            subtitle: Text(L10n.of(context).account_backup_description,
                maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const AccountBackupScreen())),
          ),
        ],
      ),
    );
  }
}
