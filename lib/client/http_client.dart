import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

const defaultHttpTimeout = Duration(seconds: 30);

/// The app-wide HTTP client. Requests carry an abort trigger as well as the
/// caller's future timeout, so expiry closes the socket instead of leaving the
/// transfer running in the background. Connections are still reused.
final TimeoutHttpClient quaxHttpClient = TimeoutHttpClient();

class TimeoutHttpClient extends http.BaseClient {
  TimeoutHttpClient({this.timeout = defaultHttpTimeout})
    : _inner = IOClient(
        HttpClient()..connectionTimeout = const Duration(seconds: 15),
      );

  final Duration timeout;
  final IOClient _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Abortable) return _inner.send(request);

    final abort = Completer<void>();
    final timer = Timer(timeout, abort.complete);
    final List<int> bytes;
    try {
      bytes = await request.finalize().toBytes();
    } catch (_) {
      timer.cancel();
      rethrow;
    }
    final wrapped =
        http.AbortableRequest(
            request.method,
            request.url,
            abortTrigger: abort.future,
          )
          ..headers.addAll(request.headers)
          ..followRedirects = request.followRedirects
          ..maxRedirects = request.maxRedirects
          ..persistentConnection = request.persistentConnection
          ..bodyBytes = bytes;

    try {
      final response = await _inner.send(wrapped);
      return http.StreamedResponse(
        _abortableBody(response.stream, timer),
        response.statusCode,
        request: request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        contentLength: response.contentLength,
        reasonPhrase: response.reasonPhrase,
      );
    } catch (_) {
      timer.cancel();
      rethrow;
    }
  }

  Future<String> readWithAbort(
    Uri uri, {
    Map<String, String>? headers,
    Future<void>? abortTrigger,
  }) async {
    final request = http.AbortableRequest(
      'GET',
      uri,
      abortTrigger: abortTrigger,
    )..headers.addAll(headers ?? const {});
    final response = await send(request);
    return response.stream.bytesToString();
  }

  Stream<List<int>> _abortableBody(Stream<List<int>> source, Timer timer) {
    late final StreamController<List<int>> controller;
    late StreamSubscription<List<int>> subscription;
    controller = StreamController<List<int>>(
      sync: true,
      onListen: () {
        subscription = source.listen(
          controller.add,
          onError: controller.addError,
          onDone: () {
            timer.cancel();
            controller.close();
          },
        );
      },
      onPause: () => subscription.pause(),
      onResume: () => subscription.resume(),
      onCancel: () {
        timer.cancel();
        return subscription.cancel();
      },
    );
    return controller.stream;
  }

  @override
  void close() => _inner.close();
}
