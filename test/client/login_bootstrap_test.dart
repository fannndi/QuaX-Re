import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/login_bootstrap.dart';

void main() {
  group('parseLoginBootstrap', () {
    // The shape x.com serves in its bootstrap user entity (captured 2026-10):
    // the handle and the numeric id sit next to each other.
    const window = '"users":{"entities":{"971742411851317248":{"name":"fandi add",'
        '"screen_name":"fandi_add","id_str":"971742411851317248","favourites_count":1}}}';

    test('Should read the handle and its numeric id', () {
      final parsed = parseLoginBootstrap('fandi_add|||$window');

      expect(parsed.screenName, 'fandi_add',
          reason: 'The login flow stores this handle to show the account; losing it leaves the '
              'account sheet without a name');
      expect(parsed.userId, '971742411851317248',
          reason: 'The Likes endpoint takes this id as userId; storing the ct0 token instead makes '
              'the tab answer empty forever');
    });

    test('Should leave the id null when the page hides it', () {
      final parsed = parseLoginBootstrap('fandi_add|||"screen_name":"fandi_add"}');

      expect(parsed.screenName, 'fandi_add',
          reason: 'The handle is still usable without the id, and the likes tab can resolve the id '
              'later through the profile endpoint');
      expect(parsed.userId, isNull,
          reason: 'A missing id must not invent one — the tab has to fall back to the profile '
              'request instead');
    });

    test('Should return an empty handle when the payload has none', () {
      final parsed = parseLoginBootstrap('');

      expect(parsed.screenName, isEmpty,
          reason: 'The login loop keeps polling while the handle is empty, so a missing payload '
              'has to read as empty rather than throw');
      expect(parsed.userId, isNull,
          reason: 'Nothing was found, so there is no id either');
    });
  });
}
