import 'package:flutter_test/flutter_test.dart';
import 'package:quax/utils/twitter_dates.dart';

void main() {
  group('convertTwitterDateTime()', () {
    test('Should read the ISO form the modern API sends', () {
      final parsed = convertTwitterDateTime('2026-10-04T18:23:11.000Z');

      expect(parsed?.toUtc(), DateTime.utc(2026, 10, 4, 18, 23, 11),
          reason: 'Every tweet card shows this timestamp, so an unreadable one makes the post '
              'undated rather than merely misformatted');
    });

    test('Should read the legacy form, which still turns up on unmigrated fields', () {
      final parsed = convertTwitterDateTime('Wed Oct 11 00:00:00 +0000 2017');

      expect(parsed?.toUtc(), DateTime.utc(2017, 10, 11),
          reason: 'The legacy `Wed Oct 11 00:00:00 +0000 2017` shape is what the 1.1 API wrote, '
              'and DateTime.parse cannot read it at all');
    });

    test('Should apply a non-UTC legacy offset instead of shifting it', () {
      final positive = convertTwitterDateTime('Wed Oct 11 00:00:00 +0200 2017');
      final negative = convertTwitterDateTime('Wed Oct 11 00:00:00 -0500 2017');

      expect(positive?.toUtc(), DateTime.utc(2017, 10, 10, 22),
          reason: '00:00 at +0200 is 22:00 UTC the day before');
      expect(negative?.toUtc(), DateTime.utc(2017, 10, 11, 5),
          reason: '00:00 at -0500 is 05:00 UTC; dropping the sign shifted it five hours the wrong way');
    });

    test('Should return null for a missing or unreadable date', () {
      expect(convertTwitterDateTime(null), isNull,
          reason: 'A field the API left out means "no date", not a crash');
      expect(convertTwitterDateTime(''), isNull, reason: 'An empty string is not a date');
      expect(convertTwitterDateTime('not a date at all'), isNull,
          reason: 'Callers treat null as "no date"; a throw would take the whole tweet down');
      expect(convertTwitterDateTime('Wed Oct 11 00:00:00 +0000'), isNull,
          reason: 'A legacy string with the year chopped off is not parseable by either branch');
    });
  });

  group('formatTwitterDateString()', () {
    test('Should drop the timezone offset so DateFormat can read the rest', () {
      expect(formatTwitterDateString('Wed Oct 11 00:00:00 +0000 2017'), 'Wed Oct 11 00:00:00 2017',
          reason: 'The format pattern has no timezone slot, so the offset has to go');
    });

    test('Should leave a string with no offset alone', () {
      expect(formatTwitterDateString('Wed Oct 11 00:00:00 2017'), 'Wed Oct 11 00:00:00 2017',
          reason: 'Nothing matches an offset, so nothing should be removed');
    });

    test('Should drop a negative offset too', () {
      expect(formatTwitterDateString('Wed Oct 11 00:00:00 -0500 2017'), 'Wed Oct 11 00:00:00 2017',
          reason: 'Dropping only +0000 left -0500 in the string and DateFormat returned null');
    });
  });
}
