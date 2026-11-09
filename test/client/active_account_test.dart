import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/accounts.dart';

void main() {
  tearDown(() {
    activeAccount.value = null;
  });

  group('setActiveAccountUserId()', () {
    test('Should not stamp an id on an account that became active during the fetch', () async {
      activeAccount.value =
          const ActiveAccount(id: 'ct0-new', screenName: 'new', localId: 'local-new');
      final revision = accountsRevision.value;

      await setActiveAccountUserId('123456', expectedAccountId: 'ct0-old');

      expect(activeAccount.value?.userId, isNull,
          reason: 'The profile request belonged to the account that was active when it started; '
              'after a switch its numeric id must not be written to the new account, which would '
              'point the Likes tab and the vault export at the wrong user');
      expect(accountsRevision.value, revision,
          reason: 'A dropped write must not look like an account switch; feed state listens to '
              'this counter');
    });
  });
}
