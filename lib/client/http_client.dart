import 'package:http/http.dart' as http;

/// The app-wide HTTP client. The top-level `http.get`/`http.post` helpers open
/// a connection, run the request and close it, so every GraphQL page fetch
/// paid a fresh TCP/TLS handshake; a shared client keeps connections warm and
/// reuses them across requests.
final http.Client quaxHttpClient = http.Client();
