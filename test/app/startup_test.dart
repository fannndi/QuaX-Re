import 'package:flutter_test/flutter_test.dart';
import 'package:pref/pref.dart';
import 'package:quax/app/startup.dart';
import 'package:quax/constants.dart';

/// `migrateMediaQualityPrefs` runs once per install and rewrites four settings
/// from the single "media size" key this fork used to have. It is the kind of
/// thing that quietly misbehaves on exactly one path — the upgrade — so each
/// starting state gets its own case.
void main() {
  BasePrefService prefsWith(Map<String, dynamic> values) => PrefServiceCache(cache: values);

  group('migrateMediaQualityPrefs()', () {
    test('Should split one quality into the image and the video setting', () async {
      final prefs = prefsWith({optionImageQuality: 'small'});

      await migrateMediaQualityPrefs(prefs);

      expect(prefs.get<String>(optionImageQuality), 'small',
          reason: 'The reader chose it, so the migration may narrow it but not invent another');
      expect(prefs.get<String>(optionMediaVideoQuality), 'small',
          reason: 'Both settings came from one key, so both have to start from what was there');
      expect(prefs.get<bool>(optionMediaDisableAutoload), false,
          reason: 'A quality that was not "disabled" means media loaded on its own, and it still should');
    });

    test('Should turn the old "disabled" value into a quality plus a data-saver switch', () async {
      final prefs = prefsWith({optionImageQuality: 'disabled'});

      await migrateMediaQualityPrefs(prefs);

      expect(prefs.get<String>(optionImageQuality), 'large',
          reason: '"disabled" carried no quality of its own, so the most detailed one stands in '
              'rather than leaving the setting unreadable');
      expect(prefs.get<String>(optionMediaVideoQuality), 'large',
          reason: 'The video setting is derived from the same key and has to agree with the image one');
      expect(prefs.get<bool>(optionMediaDisableAutoload), true,
          reason: 'What "disabled" meant — do not fetch media until asked — lives on in the switch, '
              'and losing it would start spending the reader\'s data again');
    });

    test('Should fall back to a medium quality when there was no setting at all', () async {
      final prefs = prefsWith({});

      await migrateMediaQualityPrefs(prefs);

      expect(prefs.get<String>(optionImageQuality), 'medium',
          reason: 'A reader with no preference has to land on something, not on null');
      expect(prefs.get<bool>(optionMediaDisableAutoload), false,
          reason: 'No old value means media always loaded, so the switch starts off');
    });

    test('Should mark itself done so it does not run again', () async {
      final prefs = prefsWith({optionImageQuality: 'small'});

      await migrateMediaQualityPrefs(prefs);
      await prefs.set(optionImageQuality, 'large');
      await migrateMediaQualityPrefs(prefs);

      expect(prefs.get<String>(optionImageQuality), 'large',
          reason: 'Running the migration a second time would overwrite the choice the reader made '
              'after it, dragging their setting back to what it was before the upgrade');
      expect(prefs.get<bool>(optionMediaQualitySplitMigrated), isTrue,
          reason: 'The flag is what stops it, so it has to be written for the next launch too');
    });

    test('Should not touch settings it does not own', () async {
      final prefs = prefsWith({optionImageQuality: 'small', optionThemeMode: 'dark'});

      await migrateMediaQualityPrefs(prefs);

      expect(prefs.get<String>(optionThemeMode), 'dark',
          reason: 'A migration for media quality has no business rewriting anything else');
    });
  });
}
