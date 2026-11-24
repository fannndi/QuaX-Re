import 'package:dart_twitter_api/twitter_api.dart' hide Size;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/profile/profile_model.dart';
import 'package:quax/user.dart';

void main() {
  testWidgets(
    'Should render a sparse profile without description or URL entities',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final user = UserWithExtra.fromArguments(
        idStr: '1',
        name: 'Sparse profile',
        screenName: 'sparse',
        description: 'A bio with no entity table',
        url: 'https://short.example',
        possiblySensitive: true,
        entities: UserEntities()..url = (UserEntityUrl()..urls = []),
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            L10n.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: L10n.delegate.supportedLocales,
          home: PrefService(
            service: PrefServiceCache(cache: {optionTweetsHideSensitive: true}),
            child: ProfileScreenBody(
              profile: Profile(user, const []),
              defaultTabIndex: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final error = tester.takeException();
      expect(
        error,
        isNot(isA<TypeError>()),
        reason:
            'X often omits description entities and returns a URL with no matching '
            'entity; neither sparse shape may trigger a null assertion in the profile header',
      );
      expect(
        find.text('A bio with no entity table'),
        findsOneWidget,
        reason: 'The bio must still render as plain text when its entity table is missing',
      );
    },
  );
}
