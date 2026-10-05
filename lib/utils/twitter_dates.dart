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
      final dateString = formatTwitterDateString(twitterDateString);
      return DateFormat('E MMM dd HH:mm:ss yyyy', 'en_US').parse(dateString, true);
    } catch (e) {
      return null;
    }
  }
}

/// Drops the trailing timezone offset, which is always `+0000` on these
/// strings, so the format above has something `DateFormat` can read.
String formatTwitterDateString(String twitterDateString) {
  final sanitized = twitterDateString.split(' ')..removeWhere((part) => part.startsWith('+'));

  return sanitized.join(' ');
}
