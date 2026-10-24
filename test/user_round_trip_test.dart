import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/user.dart';

void main() {
  group('UserWithExtra.toJson()/fromJson()', () {
    test('Should carry possiblySensitive through a round-trip', () {
      final user = UserWithExtra.fromNonLegacyJson({
        'rest_id': '1',
        'core': {'screen_name': 'dogs', 'name': 'Dogs'},
        'is_blue_verified': true,
        'possibly_sensitive': true,
      });

      final back = UserWithExtra.fromJson(jsonDecode(jsonEncode(user.toJson())) as Map<String, dynamic>);

      expect(back.possiblySensitive, isTrue,
          reason: 'The sensitive-content reveal reads this flag. toJson wrote it as '
              '"potentiallySensitive" while fromJson read "possibly_sensitive", so every '
              'round-trip silently dropped it and a sensitive profile was shown unguarded');
    });

    test('Should carry followedByViewer through a round-trip', () {
      final user = UserWithExtra.fromNonLegacyJson({
        'rest_id': '2',
        'core': {'screen_name': 'cats', 'name': 'Cats'},
        'legacy': {
          'relationship_perspectives': {'following': true}
        },
      });

      final back = UserWithExtra.fromJson(jsonDecode(jsonEncode(user.toJson())) as Map<String, dynamic>);

      expect(back.followedByViewer, isTrue,
          reason: 'The profile header shows a "following" chip from this flag, and toJson never '
              'wrote it at all');
    });

    test('Should keep a null as a null rather than inventing a value', () {
      final user = UserWithExtra.fromNonLegacyJson({
        'rest_id': '3',
        'core': {'screen_name': 'birds', 'name': 'Birds'},
      });

      final back = UserWithExtra.fromJson(jsonDecode(jsonEncode(user.toJson())) as Map<String, dynamic>);

      expect(back.possiblySensitive, isNull,
          reason: 'A user with no sensitivity flag must not come back flagged, or the reveal '
              'would hide ordinary profiles');
      expect(back.followedByViewer, isNull,
          reason: 'Same for the follow state: an unknown must not read as "following"');
    });
  });
}
