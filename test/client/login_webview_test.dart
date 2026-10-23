import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/login_webview.dart';

void main() {
  group('isAllowedLoginHost()', () {
    test('Should allow the hosts the login flow itself uses', () {
      expect(isAllowedLoginHost('https://x.com/i/flow/login'), isTrue,
          reason: 'The login page itself is where the flow starts, so it must always load');
      expect(isAllowedLoginHost('https://x.com/home'), isTrue,
          reason: 'The flow completes when the URL reaches x.com/home');
      expect(isAllowedLoginHost('https://api.x.com/1.1/guest/activate.json'), isTrue,
          reason: 'The flow moves between x.com and api.x.com, and blocking the second would '
              'break the login outright');
    });

    test('Should allow Google, because "Sign in with Google" is part of the flow', () {
      expect(isAllowedLoginHost('https://accounts.google.com/o/oauth2/auth'), isTrue,
          reason: 'The SSO path is a first-class login route, so its host has to be allowed or '
              'that login becomes impossible');
      expect(isAllowedLoginHost('https://ssl.gstatic.com/x.js'), isTrue,
          reason: 'The Google sign-in page loads its own static assets');
    });

    test('Should block a lookalike host, which is the whole point', () {
      expect(isAllowedLoginHost('https://x.com.evil.tld/login'), isFalse,
          reason: 'A subdomain-of-something-else host is not x.com: exact matching is what stops '
              'a phishing page from rendering inside a WebView that holds the X session cookies');
      expect(isAllowedLoginHost('https://xn--x-1ub.com/'), isFalse,
          reason: 'A punycode lookalike looks identical to x.com on screen and is not x.com');
      expect(isAllowedLoginHost('https://x.com.evil.tld.evil.tld/'), isFalse,
          reason: 'Chaining suffixes does not make a host trusted');
      expect(isAllowedLoginHost('https://twitter.com.evil.tld/'), isFalse,
          reason: 'The same rule applies to the twitter.com alias the manifest already declares');
    });

    test('Should block hosts that merely mention an allowed one', () {
      expect(isAllowedLoginHost('https://notx.com/'), isFalse,
          reason: 'A host that ends with the allowed name is a different host');
      expect(isAllowedLoginHost('https://x.community.example/'), isFalse,
          reason: 'Prefix matching would let any domain starting with x.com through');
    });

    test('Should block non-https, which is where a MITM would sit', () {
      expect(isAllowedLoginHost('http://x.com/i/flow/login'), isFalse,
          reason: 'Plain http on the login page lets anyone on the path read the credentials and '
              'the cookies; the real flow is https only');
    });

    test('Should reject anything unparseable rather than allowing it', () {
      expect(isAllowedLoginHost(''), isFalse, reason: 'An empty URL names no host');
      expect(isAllowedLoginHost('not a url at all'), isFalse,
          reason: 'A string Uri.parse cannot read has no host to check, so it must be blocked '
              'rather than waved through');
    });

    test('Should match the host case-insensitively', () {
      expect(isAllowedLoginHost('https://X.COM/i/flow/login'), isTrue,
          reason: 'Hosts are case-insensitive on the wire, so an uppercase host is still x.com');
      expect(isAllowedLoginHost('https://Accounts.Google.COM/'), isTrue,
          reason: 'Same rule for the SSO host');
    });
  });
}
