import 'package:flutter_test/flutter_test.dart';
import 'package:quax/profile/profile.dart' show profileTabs;
import 'package:quax/utils/urls.dart';

void main() {
  Future<UriParseResult> parse(String url) => parseUri(Uri.parse(url));

  T parsedAs<T extends UriParseResult>(UriParseResult result, String reason) {
    expect(result, isA<T>(), reason: reason);
    return result as T;
  }

  ProfileTabs? tabOf(ProfileUriInfo info) {
    final index = info.profileTabIndex;
    if (index == null) {
      return null;
    }
    expect(index, inInclusiveRange(0, profileTabs.length - 1),
        reason: 'The tab index should point at a real entry of profileTabs. A -1 means the tab '
            'was not found and would be read as a position');
    return profileTabs[index].id;
  }

  group('parseUri()', () {
    group('profile links', () {
      test('Should read a plain profile link', () async {
        final profile = parsedAs<ProfileUriInfo>(await parse('https://x.com/DogsTrust'),
            'A link holding only a user name should be read as a profile link');

        expect(profile.screenName, 'DogsTrust',
            reason: 'The profile screen loads the account from this name, so it should be the '
                'single path part of the link');
        expect(tabOf(profile), isNull,
            reason: 'A plain profile link names no tab, so none should be preselected');
      });

      test('Should open the matching tab for a known sub path', () async {
        final replies = parsedAs<ProfileUriInfo>(
            await parse('https://x.com/DogsTrust/with_replies'),
            '/with_replies names an account, so it should be read as a profile link');
        expect(tabOf(replies), ProfileTabs.postsAndReplies,
            reason: 'X uses /with_replies for the posts and replies tab, so that tab should open');

        final media = parsedAs<ProfileUriInfo>(await parse('https://x.com/DogsTrust/media'),
            '/media names an account, so it should be read as a profile link');
        expect(tabOf(media), ProfileTabs.media,
            reason: 'X uses /media for the media tab, so that tab should open');
      });

      test('Should accept a sub path QuaX cannot show but open no tab', () async {
        final profile = parsedAs<ProfileUriInfo>(await parse('https://x.com/DogsTrust/lists'),
            '/lists is still a valid account link, so the profile should open instead of the '
                'link being handed to the browser');

        expect(tabOf(profile), isNull,
            reason: 'There is no Lists tab in QuaX, so no tab should be preselected');
      });

      test('Should ignore a slash at the end of the link', () async {
        final profile = parsedAs<ProfileUriInfo>(await parse('https://x.com/DogsTrust/'),
            'A slash at the end does not change what the link points to, so it should still be '
                'read as a profile');

        expect(profile.screenName, 'DogsTrust',
            reason: 'The trailing slash should not be read as an empty second path part');
      });
    });

    group('post links', () {
      test('Should read a status link', () async {
        final post = parsedAs<PostUriInfo>(await parse('https://x.com/DogsTrust/status/1729'),
            '/status/ is the normal shape of a link to one tweet, so it should be read as a post '
                'and not as a profile');

        expect(post.screenName, 'DogsTrust',
            reason: 'The author should be read from the link, so the tweet can be shown before '
                'it finishes loading');
        expect(post.id, '1729',
            reason: 'This id is sent to the API to load the tweet, so it should be the last path '
                'part and nothing else');
        expect(post.photoNumber, isNull,
            reason: 'This link points at the tweet and not at one of its images, so no image '
                'number should be set');
      });

      test('Should read a topic link, which has no user name', () async {
        final post = parsedAs<PostUriInfo>(await parse('https://x.com/i/topics/tweet/1729'),
            'This link points at one tweet, so it should be read as a post. Reading it as '
                'anything else sends the user to the wrong screen when they tap it');

        expect(post.id, '1729',
            reason: 'The id should be the last path part, the one after "tweet"');
        expect(post.screenName, isNull,
            reason: 'This kind of link carries no user name, so none should be invented. A made '
                'up one would open the wrong profile when the user taps it');
      });

      test('Should read an /i/web/status/ link, which also has no user name', () async {
        final post = parsedAs<PostUriInfo>(await parse('https://x.com/i/web/status/1729'),
            'X hands this shape out for a post opened from its own web entry point, so it has to '
                'open the tweet instead of the "unable to open link" dialog');

        expect(post.id, '1729',
            reason: 'The id is what the API loads, so it should be the part after "status"');
        expect(post.screenName, isNull,
            reason: 'No user name is carried here, and inventing one would open the wrong profile');
        expect(post.photoNumber, isNull,
            reason: 'Nothing names an image, so the tweet should open on its own terms');
      });

      test('Should read the photo number of a media link', () async {
        final post = parsedAs<PostUriInfo>(
            await parse('https://x.com/DogsTrust/status/1729/photo/2'),
            'A /photo/ link still points at a tweet, so it should be read as a post');

        expect(post.photoNumber, 2,
            reason: 'This number decides which image of the tweet opens in full screen, so it '
                'should be read from the link');
      });

      test('Should remove the FxEmbed file ending', () async {
        final post = parsedAs<PostUriInfo>(await parse('https://x.com/DogsTrust/status/1729.jpg'),
            'The .jpg ending does not stop this from being a link to a tweet, so it should be '
                'read as a post');

        expect(post.id, '1729',
            reason: 'The id is sent to the API, so the .jpg ending should be stripped first');
      });
    });

    group('unknown links', () {
      test('Should return UnknownResult for the site root', () async {
        expect(await parse('https://x.com/'), isA<UnknownResult>(),
            reason: 'The site root names no account and no tweet, so nothing should be opened');
      });

      test('Should return UnknownResult for a path that is neither a profile nor a post', () async {
        expect(await parse('https://x.com/i/flow/login'), isA<UnknownResult>(),
            reason: 'An x.com path we do not handle should go to the browser rather than open an '
                'empty profile called "i"');
      });
    });

    // TODO(test): parseUri follows t.co links over the network before reading them again. Testing
    // that needs the fake http client from the mock server work, so it is not covered here.
  });

  group('isLaunchableLink()', () {
    test('Should accept http and https links', () {
      expect(isLaunchableLink('https://x.com/user'), isTrue,
          reason: 'A normal web link is what openUri exists to hand to the browser');
      expect(isLaunchableLink('http://t.co/abc'), isTrue,
          reason: 'X still serves some links over plain http, and they are still web links');
    });

    test('Should reject schemes that reach Activity.startActivity as something else', () {
      expect(isLaunchableLink('file:///data/data/com.fannndi.quaxre/databases/quax.db'), isFalse,
          reason: 'A file:// URL handed to an external app reads a local file, which a link from '
              'X\'s API has no business doing');
      expect(isLaunchableLink('content://media/external/images/media/1'), isFalse,
          reason: 'A content:// URI exposes app-internal data to whichever app receives it');
      expect(isLaunchableLink('intent://scan/#Intent;scheme=zxing;end'), isFalse,
          reason: 'An intent:// URI resolves to another app and can carry arbitrary extras, so it '
              'must never be launched from a URL string');
      expect(isLaunchableLink('javascript:alert(1)'), isFalse,
          reason: 'A javascript: URL is not a link at all');
    });

    test('Should reject unparseable and scheme-less strings', () {
      expect(isLaunchableLink(''), isFalse, reason: 'An empty string is not a link');
      expect(isLaunchableLink('x.com/user'), isFalse,
          reason: 'Without a scheme the string is not a URL, so Uri.parse would read the whole '
              'thing as a path and the launch would fail anyway');
    });
  });

  group('parseUri() t.co chains', () {
    test('Should stop after the hop limit instead of recursing forever', () async {
      // The hop counter is checked before any request is sent, so a chain that
      // has already run out of budget never touches the network.
      expect(await parseUri(Uri.parse('https://t.co/abc'), shortUrlHops: 99), isA<UnknownResult>(),
          reason: 'A t.co link past the hop limit must resolve to nothing rather than loop: each '
              'hop is a network round-trip, and a looping shortener would hang the deep-link '
              'handler for good');
    });
  });

  group('extractPhotoNumber()', () {
    test('Should read the number after a "photo" part', () {
      expect(extractPhotoNumber(['user', 'status', '1', 'photo', '3'], 3), 3,
          reason: 'The index points at the "photo" part, so the number right after it should be '
              'the one that comes back');
    });

    test('Should return null when the part is not "photo"', () {
      expect(extractPhotoNumber(['user', 'status', '1', 'video', '3'], 3), isNull,
          reason: 'Only "photo" links carry an image number, so any other word should give null '
              'rather than the number that follows it');
    });

    test('Should return null when the number is missing or not a number', () {
      expect(extractPhotoNumber(['user', 'status', '1', 'photo'], 3), isNull,
          reason: 'A link that stops too early should give null and should not throw a RangeError');
      expect(extractPhotoNumber(['user', 'status', '1', 'photo', 'x'], 3), isNull,
          reason: 'Text that is not a number should give null rather than throw');
    });
  });

  group('host and reserved-path guards', () {
    test('Should reject a host that only looks like X', () async {
      final result = await parse('https://x.com.evil.tld/DogsTrust/status/1');

      expect(result, isA<UnknownResult>(),
          reason: 'Only the t.co hop used to be checked, so a lookalike host was parsed as an X '
              'post and opened inside the app');
    });

    test('Should send reserved X pages to the browser', () async {
      for (final path in ['home', 'search', 'explore', 'notifications', 'messages', 'settings']) {
        final result = await parse('https://x.com/$path');

        expect(result, isA<UnknownResult>(),
            reason: 'x.com/$path is not a handle; reading it as a profile showed "user not found" '
                'instead of handing the link to the browser');
      }
    });

    test('Should accept the documented X hosts', () async {
      for (final host in [
        'x.com',
        'www.x.com',
        'mobile.x.com',
        'twitter.com',
        'www.twitter.com',
        'mobile.twitter.com',
      ]) {
        final result = await parse('https://$host/DogsTrust');

        expect(result, isA<ProfileUriInfo>(),
            reason: 'A real X profile link on $host should still open the profile');
      }
    });
  });
}
