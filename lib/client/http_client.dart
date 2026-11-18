import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// The app-wide HTTP client. The top-level `http.get`/`http.post` helpers open
/// a connection, run the request and close it, so every GraphQL page fetch
/// paid a fresh TCP/TLS handshake; a shared client keeps connections warm and
/// reuses them across requests.
///
/// The connect phase is bounded here because a stalled handshake has no other
/// timeout above it: the per-request `.timeout` in the client gives up on the
/// future but leaves the socket trying. Repeated page fetches on a bad network
/// used to accumulate those sockets until the process hit its file limit.
final http.Client quaxHttpClient = IOClient(
  HttpClient()..connectionTimeout = const Duration(seconds: 15),
);
