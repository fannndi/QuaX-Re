import 'package:pref/pref.dart';
import 'package:quax/constants.dart';
import 'package:timeago/timeago.dart' as timeago;

// The UI ships English only, so relative timestamps need a single table.
// Registering every language timeago offers would pull in a few hundred KB of
// message maps that can never be reached.
void setTimeagoLocales() {
  timeago.setLocaleMessages('en', timeago.EnMessages());
}

// One-time split of the former single "media size" pref into separate image and
// video quality settings, plus a data-saver toggle for its old "disabled" value.
Future<void> migrateMediaQualityPrefs(BasePrefService prefs) async {
  if (prefs.get<bool>(optionMediaQualitySplitMigrated) ?? false) {
    return;
  }

  final previous = prefs.get<String>(optionImageQuality);
  final disabled = previous == 'disabled';
  // The old "disabled" value carried no real quality, so fall back to Maximum.
  final quality = disabled ? 'large' : (previous ?? 'medium');

  await prefs.set(optionMediaDisableAutoload, disabled);
  await prefs.set(optionImageQuality, quality);
  await prefs.set(optionMediaVideoQuality, quality);
  await prefs.set(optionMediaQualitySplitMigrated, true);
}
