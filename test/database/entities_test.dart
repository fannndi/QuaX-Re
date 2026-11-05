import 'package:flutter_test/flutter_test.dart';
import 'package:quax/database/entities.dart';

void main() {
  group('Account.isClean', () {
    test('Should be true when no 404 was ever counted', () {
      final account = Account(id: 'a', authHeader: '{}', screenName: 'a');

      expect(account.isClean, isTrue,
          reason: 'This getter is checked after every request that works, to avoid a database '
              'write. A brand new account should be clean, otherwise every request pays a write');
    });

    test('Should be false once a 404 was counted, even before the mark is set', () {
      final account = Account(id: 'a', authHeader: '{}', screenName: 'a', consecutiveNotFound: 1);

      expect(account.isClean, isFalse,
          reason: 'The counter still has to be reset on the next request that works, so this '
              'account should not be reported as clean and the write should not be skipped');
    });
  });

  group('Account.fromMap()', () {
    test('Should read a missing not found date as null instead of throwing', () {
      final account = Account.fromMap({
        'id': 'a',
        'auth_header': '{}',
        'screen_name': 'a',
        'last_not_found_at': null,
        'consecutive_not_found': null,
      });

      expect(account.lastNotFoundAt, isNull,
          reason: 'A NULL date should stay null. Reading it as a date would mark the account as '
              'broken and take it out of use');
      expect(account.consecutiveNotFound, 0,
          reason: 'Accounts added before these columns existed hold NULL there, so the counter '
              'should fall back to 0 rather than throw');
    });

    test('Should carry the numeric user id through the map', () {
      final account = Account(id: 'a', authHeader: '{}', screenName: 'dogs', userId: '42');

      expect(Account.fromMap(account.toMap()).userId, '42',
          reason: 'The likes tab reads this value as the endpoint userId; losing it across a '
              'restart re-triggers the profile resolution at every launch');
    });

    test('Should read an account saved before the id column as null', () {
      final account = Account.fromMap({
        'id': 'a',
        'auth_header': '{}',
        'screen_name': 'dogs',
      });

      expect(account.userId, isNull,
          reason: 'A missing user_id must stay null so the likes tab knows to resolve it once, '
              'rather than crash on a cast');
    });
  });
}
