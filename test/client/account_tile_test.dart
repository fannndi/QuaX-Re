import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/client/account_tile.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/generated/l10n.dart';

void main() {
  Future<void> pumpTile(WidgetTester tester, Account account,
      {VoidCallback? onRelogin}) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [L10n.delegate, ...GlobalMaterialLocalizations.delegates],
      supportedLocales: const [Locale('en')],
      locale: const Locale('en'),
      home: Scaffold(
        body: AccountTile(
          account: account,
          onRelogin: onRelogin,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Account account({
    String? displayName,
    bool active = false,
    DateTime? lastAuthErrorAt,
  }) {
    return Account(
      id: 'csrf-a',
      authHeader: '{}',
      screenName: 'alice',
      userId: '101',
      localId: 'local-a',
      displayName: displayName,
      isActive: active,
      lastAuthErrorAt: lastAuthErrorAt,
      profileFetchedAt: DateTime.now(),
    );
  }

  testWidgets('Should draw the cached display name, handle and active check', (tester) async {
    await pumpTile(tester, account(displayName: 'Alice Doe', active: true));

    expect(find.text('Alice Doe'), findsOneWidget);
    expect(find.text('@alice'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget,
        reason: 'The active login needs a visible marker in the switcher');
  });

  testWidgets('Should offer a re-login for a rejected session', (tester) async {
    var relogins = 0;
    await pumpTile(tester, account(lastAuthErrorAt: DateTime.now()),
        onRelogin: () => relogins++);

    expect(find.text('Session expired'), findsOneWidget);
    await tester.tap(find.byTooltip('Log in again'));
    await tester.pump();

    expect(relogins, 1,
        reason: 'A 401 account must have a one-tap way to replace its session instead of only '
            'showing a generic feed error');
  });
}
