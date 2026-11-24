import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/login_bootstrap.dart';

void main() {
  group('parseLoginBootstrap', () {
    // The shape x.com serves in its bootstrap user entity (captured 2026-10):
    // the handle and the numeric id sit next to each other.
    const window =
        '"users":{"entities":{"971742411851317248":{"name":"fandi add",'
        '"screen_name":"fandi_add","id_str":"971742411851317248","favourites_count":1}}}';

    test('Should read the handle and its numeric id', () {
      final parsed = parseLoginBootstrap('fandi_add|||$window');

      expect(
        parsed.screenName,
        'fandi_add',
        reason:
            'The login flow stores this handle to show the account; losing it leaves the '
            'account sheet without a name',
      );
      expect(
        parsed.userId,
        '971742411851317248',
        reason:
            'The Likes endpoint takes this id as userId; storing the ct0 token instead makes '
            'the tab answer empty forever',
      );
    });

    test('Should leave the id null when the page hides it', () {
      final parsed = parseLoginBootstrap(
        'fandi_add|||"screen_name":"fandi_add"}',
      );

      expect(
        parsed.screenName,
        'fandi_add',
        reason:
            'The handle is still usable without the id, and the likes tab can resolve the id '
            'later through the profile endpoint',
      );
      expect(
        parsed.userId,
        isNull,
        reason:
            'A missing id must not invent one — the tab has to fall back to the profile '
            'request instead',
      );
    });

    test('Should read the x-web viewer identity', () {
      const payload =
          '{"viewerScreenName":"fandi_add","viewerId":"1721809266"}';
      final parsed = parseLoginBootstrap(payload);

      expect(
        parsed.screenName,
        'fandi_add',
        reason:
            'The x-web home page keeps the logged-in handle in __INITIAL_DATA__; '
            'missing it leaves the login WebView open after X has signed in',
      );
      expect(
        parsed.userId,
        '1721809266',
        reason:
            'The numeric viewer id is required by the Likes endpoint and must '
            'come from the same identity as the handle',
      );
    });

    test('Should read a REST-shaped user identity', () {
      final parsed = parseLoginIdentity({
        'screen_name': 'fandi_add',
        'id_str': '971742411851317248',
      });

      expect(
        parsed.screenName,
        'fandi_add',
        reason: 'The handle identifies the account saved by the login flow',
      );
      expect(
        parsed.userId,
        '971742411851317248',
        reason: 'The Likes endpoint needs the numeric user id',
      );
    });

    test('Should accept a numeric rest id and reject a missing handle', () {
      final parsed = parseLoginIdentity({'rest_id': 971742411851317248});
      expect(
        parsed.screenName,
        isEmpty,
        reason: 'An id alone is not enough to name the account',
      );
      expect(
        parsed.userId,
        '971742411851317248',
        reason: 'A numeric id must survive JSON decoding as a string',
      );
    });

    test('Should reject malformed viewer JSON without throwing', () {
      final parsed = parseLoginBootstrap('{"viewerScreenName":');

      expect(
        parsed.screenName,
        isEmpty,
        reason:
            'A partial bootstrap payload must keep login polling, not crash',
      );
      expect(
        parsed.userId,
        isNull,
        reason: 'Malformed JSON cannot supply a trustworthy user id',
      );
    });

    test('Should return an empty handle when the payload has none', () {
      final parsed = parseLoginBootstrap('');

      expect(
        parsed.screenName,
        isEmpty,
        reason:
            'The login loop keeps polling while the handle is empty, so a missing payload '
            'has to read as empty rather than throw',
      );
      expect(
        parsed.userId,
        isNull,
        reason: 'Nothing was found, so there is no id either',
      );
    });
  });
}
