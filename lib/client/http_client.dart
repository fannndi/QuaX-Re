import 'package:http/http.dart' as http;

/// The app-wide HTTP client. The top-level `http.get`/`http.post` helpers open
/// a connection, run the request and close it, so every GraphQL page fetch
/// paid a fresh TCP/TLS handshake; a shared client keeps connections warm and
/// reuses them across requests.
final http.Client quaxHttpClient = http.Client();

/// This fork's release feed: an unauthenticated GET with no session, so it
/// cannot touch X state. It lives here so every request goes through the one
/// shared client and the read-only guard has a single network layer to watch.
Future<http.Response> fetchLatestRelease() => quaxHttpClient.get(
      Uri.parse('https://api.github.com/repos/fannndi/QuaX-Re/releases/latest'),
      headers: const {'user-agent': 'QuaX-Re'},
    );
