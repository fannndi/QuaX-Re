import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// The app-wide HTTP client. The top-level `http.get`/`http.post` helpers open
/// a connection, run the request and close it, so every GraphQL page fetch
/// paid a fresh TCP/TLS handshake; a shared client keeps connections warm and
/// reuses them across requests.
http.Client _quaxHttpClient = http.Client();

http.Client get quaxHttpClient => _quaxHttpClient;

/// Test hook: swaps the shared client for a mock.
@visibleForTesting
set quaxHttpClient(http.Client client) => _quaxHttpClient = client;
