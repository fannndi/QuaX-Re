import 'package:flutter_test/flutter_test.dart';
import 'package:quax/constants.dart';

void main() {
  test('Should pin every GraphQL operation to the 2026-11-20 community contract', () {
    const expected = <String, (String, String)>{
      'HomeTimeline': ('GET', 'KmJCeZ__ef1fNos7tKN_fg'),
      'HomeLatestTimeline': ('POST', 'IVA5BUbeYPTrpYekQH7jiA'),
      'UserByRestId': ('GET', 'mxaYWwt52eAb6OAzYHMVzg'),
      'UserByScreenName': ('GET', 'AMIBMjtxEEATh4z8V9GtRg'),
      'Following': ('GET', 'eDqlbOS46zda8jDT8dEQ_Q'),
      'Followers': ('GET', 'Xe3y9_ndZ9-RtWz8zd_wpg'),
      'TweetDetail': ('GET', 'dQDdKtt882nl-Km98FJGSQ'),
      'SearchTimeline': ('GET', 'vLHjqbDv7TPFMBkIIO1nOA'),
      'Likes': ('GET', 'ZjyvI1V9gajq5eclHCObzA'),
      'Bookmarks': ('GET', 'fjf5b5Lu82lYMSBRhppK2g'),
      'UserVideoTimeline': ('GET', '1UmMb8X-BFHS98GG6DyRsQ'),
      'UserMedia': ('GET', 'QWOimofaocjeRda7Tm5pNA'),
      'UserRepliesTimeline': ('GET', 'fpl-c0_APDI3nZ1CeeBMbg'),
      'UserOriginalsTimeline': ('GET', 'ZFKu1DFS63hgrkLzR3Hsdw'),
    };

    expect(
      graphQlEndpoints.keys,
      unorderedEquals(expected.keys),
      reason: 'An operation added to the client must be added to the registry and live probe',
    );
    for (final entry in expected.entries) {
      final endpoint = graphQlEndpoints[entry.key]!;
      expect(
        (endpoint.method, endpoint.queryId),
        entry.value,
        reason:
            '${entry.key} is version-pinned; a stale id answers 404 and a stale method '
            'can silently return an archived response',
      );
      expect(
        endpoint.operation,
        entry.key,
        reason: 'The registry key and GraphQL path operation must agree',
      );
      expect(
        endpoint.expectedRoot,
        isNotEmpty,
        reason: 'Every operation needs a root contract so HTTP 200 shape changes fail before parsing',
      );
    }
  });

  test('Should build version-pinned x.com paths from the registry', () {
    final endpoint = graphQlEndpoints['HomeLatestTimeline']!;
    final uri = endpoint.uri(variables: const {'count': 20});

    expect(
      uri.toString(),
      'https://x.com/i/api/graphql/IVA5BUbeYPTrpYekQH7jiA/HomeLatestTimeline?variables=%7B%22count%22%3A20%7D',
      reason: 'Client and probe must issue the same host, query id, operation and encoding',
    );
  });
}
