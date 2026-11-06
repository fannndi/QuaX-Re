import 'package:intl/intl.dart';

/// Parses a timestamp the way X writes them: an ISO string first, then the
/// older `Wed Oct 11 00:00:00 +0000 2017` form that still turns up on fields
/// the API has not migrated.
///
/// Vendored from `dart_twitter_api`'s `src/utils/date_utils.dart`: the package
/// does not export it, and reaching into `src/` means a version bump can break
/// the build. Parsing runs for every tweet in a page, so the fixtures in
/// `test/client/` exercise this on a wide range of recorded responses.
///
/// Returns null when neither form parses, which the callers treat as "no date"
/// rather than an error.
DateTime? convertTwitterDateTime(String? twitterDateString) {
  if (twitterDateString == null) {
    return null;
  }

  try {
    return DateTime.parse(twitterDateString);
  } catch (e) {
    try {
      final wall = DateFormat('E MMM dd HH:mm:ss yyyy', 'en_US')
          .parse(formatTwitterDateString(twitterDateString), true);
      final offset = RegExp(r'([+-])(\d{2})(\d{2})(?=\s|$)').firstMatch(twitterDateString);
      if (offset == null) return wall;

      // The legacy form carries the offset as a trailing token. Parsing the
      // wall time as UTC and then applying it gives the real instant; the old
      // code dropped only `+` and silently shifted `-0500` by five hours.
      final sign = offset.group(1) == '-' ? -1 : 1;
      final minutes = sign *
          (int.parse(offset.group(2)!) * 60 + int.parse(offset.group(3)!));
      return wall.subtract(Duration(minutes: minutes));
    } catch (e) {
      return null;
    }
  }
}

/// Drops the trailing timezone offset so the format above has something
/// `DateFormat` can read. Both signs occur; dropping only `+` left `-0500` in
/// the string and the parse returned null.
String formatTwitterDateString(String twitterDateString) {
  final sanitized = twitterDateString.split(' ')
    ..removeWhere((part) => RegExp(r'^[+-]\d{4}$').hasMatch(part));

  return sanitized.join(' ');
}
