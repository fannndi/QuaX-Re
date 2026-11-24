import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/ui/passphrase_dialog.dart';

void main() {
  Future<void> pumpLauncher(
    WidgetTester tester,
    void Function(String?) onResult, {
    bool confirm = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          L10n.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('en')],
        locale: const Locale('en'),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                final value = await showVaultPassphraseDialog(
                  context,
                  confirm: confirm,
                );
                onResult(value);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('Should reject a short or mismatched passphrase before closing', (
    tester,
  ) async {
    String? value;
    await pumpLauncher(tester, (v) => value = v);

    await tester.enterText(find.byType(TextField).at(0), 'short');
    await tester.enterText(find.byType(TextField).at(1), 'short');
    await tester.tap(find.text('OK'));
    await tester.pump();

    expect(
      find.textContaining('At least 12'),
      findsOneWidget,
      reason:
          'A short passphrase protecting a live session should be stopped in the dialog, '
          'not several screens later',
    );

    await tester.enterText(
      find.byType(TextField).at(0),
      'correct horse battery',
    );
    await tester.enterText(
      find.byType(TextField).at(1),
      'different horse battery',
    );
    await tester.tap(find.text('OK'));
    await tester.pump();

    expect(
      find.textContaining('do not match'),
      findsOneWidget,
      reason: 'A typo in the confirmation would make the vault impossible to reopen',
    );
    expect(
      value,
      isNull,
      reason: 'The dialog must stay open while the confirmation is wrong',
    );
  });

  testWidgets('Should accept an older short passphrase when opening a vault', (
    tester,
  ) async {
    String? value;
    await pumpLauncher(tester, (v) => value = v, confirm: false);

    await tester.enterText(find.byType(TextField), 'legacy123');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(
      value,
      'legacy123',
      reason:
          'The twelve-character minimum applies to new vaults, not to opening one written '
          'by an older version',
    );
  });

  testWidgets('Should return the passphrase once both fields agree', (
    tester,
  ) async {
    String? value;
    await pumpLauncher(tester, (v) => value = v);

    await tester.enterText(
      find.byType(TextField).at(0),
      '  correct horse battery  ',
    );
    await tester.enterText(
      find.byType(TextField).at(1),
      'correct horse battery',
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(
      value,
      'correct horse battery',
      reason:
          'The caller needs the trimmed passphrase that will encrypt the vault',
    );
    expect(
      find.byType(AlertDialog),
      findsNothing,
      reason: 'A valid confirmed passphrase closes the dialog',
    );
  });
}
