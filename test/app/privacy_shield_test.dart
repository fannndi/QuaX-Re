import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pref/pref.dart';
import 'package:quax/app/privacy_shield.dart';
import 'package:quax/constants.dart';

class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('route B'))),
          ),
          child: const Text('open'),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('Should keep the open route across a background cycle', (tester) async {
    final prefs = PrefServiceCache(cache: {optionDisableScreenshots: false});

    await tester.pumpWidget(MaterialApp(
      home: PrefService(
        service: prefs,
        child: PrivacyShield(
          child: Navigator(
            onGenerateRoute: (settings) =>
                MaterialPageRoute<void>(builder: (_) => const _Home()),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('route B'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('route B'), findsOneWidget,
        reason: 'The shield used to swap the Navigator between bare and Stack on every background, '
            'which remounted the whole subtree and dropped the open route');
  });
}
