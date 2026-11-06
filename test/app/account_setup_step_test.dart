import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:quax/app/account_setup_step.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/generated/l10n.dart';

void main() {
  Future<void> pumpStep(
    WidgetTester tester, {
    List<Account> accounts = const [],
    bool hasVault = false,
  }) async {
    await tester.pumpWidget(PrefService(
      service: PrefServiceCache(),
      child: MaterialApp(
        localizationsDelegates: const [L10n.delegate, ...GlobalMaterialLocalizations.delegates],
        supportedLocales: const [Locale('en')],
        locale: const Locale('en'),
        home: Scaffold(
          body: AccountSetupStep(
            libraryPath: '/tmp/QuaXLibrary',
            loadAccounts: () async => accounts,
            vaultExists: (_) async => hasVault,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('Should offer login and import when the app has nothing yet', (tester) async {
    await pumpStep(tester);

    expect(find.text('No accounts yet.'), findsOneWidget);
    expect(find.text('Log in now'), findsOneWidget);
    expect(find.text('Import from file'), findsOneWidget);
    expect(find.text('Account backup found'), findsNothing,
        reason: 'There is no vault yet, so the restore card must not promise one');
  });

  testWidgets('Should show the accounts already available', (tester) async {
    await pumpStep(tester, accounts: [
      Account(
        id: 'csrf-a',
        authHeader: '{}',
        screenName: 'alice',
        localId: 'local-a',
        isActive: true,
      )
    ]);

    expect(find.text('1 account ready'), findsOneWidget);
    expect(find.text('@alice'), findsOneWidget);
    expect(find.text('Create account backup'), findsOneWidget,
        reason: 'An account without a vault is exactly the state that needs a backup');
  });

  testWidgets('Should show the restore card when a vault exists', (tester) async {
    await pumpStep(tester, hasVault: true);

    expect(find.text('Account backup found'), findsOneWidget);
    expect(find.text('Restore accounts'), findsOneWidget);
  });
}
