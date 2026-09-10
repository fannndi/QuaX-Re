import 'package:material_ui/material_ui.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/client.dart';
import 'package:quax/client/client_regular_account.dart';
import 'package:quax/client/login_webview.dart';
import 'package:quax/constants.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/profile/_likes.dart';
import 'package:quax/profile/profile.dart';

/// The accounts screen: add an account, delete one (swipe), pick the one the
/// app talks to — and jump into your own profile or your likes.
class SettingsAccountFragment extends StatefulWidget {
  const SettingsAccountFragment({super.key});

  @override
  State<SettingsAccountFragment> createState() => _SettingsAccountFragment();
}

class _SettingsAccountFragment extends State<SettingsAccountFragment> {
  Future<void> _activate(Account account) async {
    await setActiveAccount(account.id);
    if (mounted) setState(() {});
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
      body: FutureBuilder(
          future: getAccounts(),
          builder: (BuildContext listContext, AsyncSnapshot snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const LinearProgressIndicator();
            }

            List<Account> data = snapshot.data;
            if (data.isEmpty) {
              return const SizedBox.shrink();
            }

            return ListView.builder(
                itemCount: data.length,
                itemBuilder: (BuildContext itemContext, int index) {
                  final account = data[index];
                  return Dismissible(
                      key: ValueKey(account.id),
                      onDismissed: (DismissDirection direction) async {
                        await model.deleteAccount(account.id);
                        setState(() {});
                      },
                      child: Card(
                          child: ListTile(
                        title: Text(account.screenName ?? L10n.of(context).unknown_username),
                        leading: Icon(account.isActive ? Icons.radio_button_checked : Icons.account_circle),
                        trailing: IconButton(
                          icon: const Icon(Icons.person_outline),
                          onPressed: () => _openProfile(account),
                        ),
                        selected: account.isActive,
                        onTap: account.isActive ? null : () => _activate(account),
                      )));
                });
          }),
    );
  }
}
