import 'package:flutter_test/flutter_test.dart';
import 'package:quax/utils/tweet_freshness_index.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TweetFreshnessIndex().resetForTesting();
  });

  tearDown(() => TweetFreshnessIndex().resetForTesting());

  test('Should trim remembered tweet ids by numeric snowflake order', () async {
    final index = TweetFreshnessIndex();
    await index.load();
    index.note([
      for (var i = 1; i <= 3000; i++) '$i',
      '999999999999999999',
      '1000000000000000000',
    ]);

    await index.saveNowForTesting();

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('freshness.v1.ids')!;
    expect(
      saved,
      hasLength(3000),
      reason: 'The persisted freshness snapshot stays within its memory bound',
    );
    expect(
      saved,
      contains('999999999999999999'),
      reason: 'The smaller of two large snowflakes is still newer than the small legacy ids',
    );
    expect(
      saved,
      contains('1000000000000000000'),
      reason: 'Numeric order must keep the largest snowflake even though its text sorts first',
    );
    expect(
      saved,
      isNot(contains('1')),
      reason: 'The oldest numeric ids are the ones that must leave the bounded snapshot',
    );
  });
}
