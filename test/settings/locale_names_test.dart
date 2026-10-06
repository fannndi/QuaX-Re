import 'package:flutter_test/flutter_test.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/settings/native_locale_names.dart';

void main() {
  // be_Latn is the one locale flutter_localized_locales never had a native
  // name for, so it has always shown its own code. Listed here rather than
  // special-cased below, so a locale added tomorrow cannot hide behind it.
  const withoutName = {'be_Latn'};

  group('nativeLocaleNames', () {
    test('Should name every locale the settings screen offers', () {
      final offered = L10n.delegate.supportedLocales
          .map((l) => l.toLanguageTag().replaceAll('-', '_'))
          .toSet();

      final unnamed = offered.difference(nativeLocaleNames.keys.toSet()).difference(withoutName);

      expect(unnamed, isEmpty,
          reason: 'A locale without a native name renders as its raw code in the language picker '
              '("zh_Hans" instead of "中文 (简体中文)"), which is not a name a reader can act on. '
              'Add it to lib/settings/native_locale_names.dart.');
    });

    test('Should not carry names for locales the app does not offer', () {
      final offered = L10n.delegate.supportedLocales
          .map((l) => l.toLanguageTag().replaceAll('-', '_'))
          .toSet();

      final surplus = nativeLocaleNames.keys.toSet().difference(offered);

      expect(surplus, isEmpty,
          reason: 'Every entry costs bytes in the APK; this map exists because only these locales '
              'are labelled, so one appearing here means it was added without a locale behind it');
    });

    test('Should show a name rather than the code, except where none exists', () {
      for (final locale in L10n.delegate.supportedLocales) {
        final code = locale.toLanguageTag().replaceAll('-', '_');
        if (withoutName.contains(code)) continue;

        expect(nativeLocaleNames[code], isNotNull,
            reason: '"$code" would be shown to the reader as itself, in the picker where they '
                'choose the language');
      }
    });

    test('Should keep the name the locale is known by in its own language', () {
      expect(nativeLocaleNames['id'], 'Bahasa Indonesia',
          reason: 'The point of the map is the name in the locale\'s own script, not the English '
              'one — "Indonesian" here would defeat it');
      expect(nativeLocaleNames['ja'], '日本語',
          reason: 'Same: the label has to be readable by the reader who is picking it');
    });
  });
}
