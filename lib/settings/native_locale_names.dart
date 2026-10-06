/// The language picker's labels: each supported locale's name written the way
/// its own speakers write it — "日本語" for Japanese, "Bahasa Indonesia" for
/// Indonesian — so the list reads in the language the reader is choosing.
///
/// Vendored from `flutter_localized_locales`, whose `nativeLocaleNames` ships
/// 563 locales as JSON in the asset bundle: 15 MB of the APK to label the 29
/// this app offers. A locale missing here falls back to its own code, which is
/// what `be_Latn` did under the package too — it is the one supported locale
/// the package never had a name for.
const Map<String, String> nativeLocaleNames = {
  "en": "English",
  "ar": "العربية",
  "be": "беларуская",
  "ca": "català",
  "cs": "čeština",
  "de": "Deutsch",
  "eo": "esperanto",
  "es": "español",
  "et": "eesti",
  "eu": "euskara",
  "fr": "français",
  "hi": "हिंदी",
  "id": "Bahasa Indonesia",
  "it": "italiano",
  "ja": "日本語",
  "ko": "한국어",
  "nb_NO": "norsk bokmål (Norge)",
  "nl": "Nederlands",
  "pl": "polski",
  "pt": "português",
  "pt_BR": "português (Brasil)",
  "ro": "română",
  "ru": "русский",
  "tr": "Türkçe",
  "uk": "українська",
  "vi": "Tiếng Việt",
  "zh_Hans": "中文 (简体中文)",
  "zh_Hant": "中文 (繁體)",
};
