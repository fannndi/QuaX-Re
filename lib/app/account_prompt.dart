import 'package:material_ui/material_ui.dart';
import 'package:logging/logging.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/settings/_data.dart';
import 'package:quax/client/login_webview.dart';
import 'package:quax/generated/l10n.dart';
Future checkForAccounts(context) async {
  Logger.root.info('Checking for accounts');

  final accounts = await getAccounts();
  if (accounts.isEmpty) {
    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text("⚠️ ${L10n.of(context).not_logged_in}"),
          content: Text(L10n.of(context).quax_doesnt_work_without_account_please_login),
          actions: [
            TextButton(
              child: Text(L10n.of(context).import_backup),
              onPressed: () async {
                await importBackup(context);
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
              },
            ),
            TextButton(
              child: Text(L10n.of(context).login),
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.push(context, MaterialPageRoute(builder: (_) => const TwitterLoginWebview()));
              },
            ),
          ],
        );
      },
    );
  }
}


