import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pref/pref.dart';
import 'package:quax/cached/cached_tweets_model.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/rate_limit_tracker.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/downloads/video_cache.dart';
import 'package:quax/utils/tweet_freshness_index.dart';
import 'package:sqflite_common/sqlite_api.dart' as sqlite;

/// A machine-readable diagnostics surface for development agents.
///
/// In debug and profile builds the app serves a JSON API on its loopback
/// interface (never on a network interface, and never in release builds).
/// The agent on the host machine reaches it with `adb reverse` and reads it
/// over plain HTTP — see tool/debug/probe.dart. The payload is a snapshot of
/// app state that is safe to share: account auth headers are never included,
/// and log records are redacted of bearer tokens.
///
/// Endpoints:
///   GET /            endpoint index
///   GET /ping        liveness + version + chosen port
///   GET /dump        everything below in one document
///   GET /logs?since=N  log records newer than sequence N (default: all)
///   GET /prefs       current preference values
///   GET /db          schema version and row counts (no row contents)
class DebugBridge {
  static final DebugBridge _instance = DebugBridge._();

  factory DebugBridge() => _instance;

  DebugBridge._();

  static const _firstPort = 8642;
  static const _lastPort = 8652;
  static const _ringCapacity = 250;
  static const _messageCap = 1500;
  static const _stackLineCap = 10;

  final List<Map<String, dynamic>> _ring = [];
  int _sequence = 0;
  HttpServer? _server;
  BasePrefService? _prefs;
  int _port = 0;
  String _version = '?';

  bool get isRunning => _server != null;
  int get port => _port;

  /// Clears the module state between tests: ring, sequence and server.
  @visibleForTesting
  Future<void> stopForTests() async {
    await _server?.close(force: true);
    _server = null;
    _ring.clear();
    _sequence = 0;
    _port = 0;
  }

  /// Attaches the log sink and starts the loopback server. Safe to call more
  /// than once; the server starts only in debug/profile builds, and only one
  /// server is kept. [firstPort]/[lastPort] narrow the port search in tests.
  Future<void> start(
    BasePrefService prefs, {
    int firstPort = _firstPort,
    int lastPort = _lastPort,
  }) async {
    _prefs = prefs;
    if (kReleaseMode || _server != null) {
      return;
    }

    try {
      final info = await PackageInfo.fromPlatform();
      _version = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // Version metadata is nice-to-have.
    }

    for (var port = firstPort; port <= lastPort; port++) {
      try {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        _port = port;
        break;
      } on SocketException {
        continue;
      }
    }

    final server = _server;
    if (server == null) {
      _announce('no free port in range $firstPort-$lastPort');
      return;
    }

    server.listen(
      _serve,
      onError: (Object e) {
        _announce('listener error $e');
      },
    );
    _announce('port=$_port');
  }

  /// Appends one logging record to the ring buffer. Called from the
  /// Logger.root listener, so it must stay cheap and never throw.
  void record(LogRecord record) {
    if (kReleaseMode) {
      return;
    }
    _add(
      level: record.level.name,
      logger: record.loggerName,
      message: record.message,
      error: record.error,
      stackTrace: record.stackTrace,
    );
  }

  /// Records a crash-like event with full context (uncaught or framework).
  void event(
    String logger,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (kReleaseMode) {
      return;
    }
    _add(
      level: 'SEVERE',
      logger: logger,
      message: message,
      error: error,
      stackTrace: stackTrace,
    );
  }

  void _add({
    required String level,
    required String logger,
    required String message,
    Object? error,
    StackTrace? stackTrace,
  }) {
    String redacted = _redact(message);
    if (redacted.length > _messageCap) {
      redacted = redacted.substring(0, _messageCap);
    }
    final entry = <String, dynamic>{
      'n': _sequence++,
      't': DateTime.now().toIso8601String(),
      'l': level,
      'lg': logger,
      'm': redacted,
    };
    if (error != null) {
      String errorText = _redact(error.toString());
      if (errorText.length > _messageCap) {
        errorText = errorText.substring(0, _messageCap);
      }
      entry['e'] = errorText;
    }
    final stack = stackTrace
        ?.toString()
        .split('\n')
        .take(_stackLineCap)
        .join('\n');
    if (stack != null && stack.isNotEmpty) {
      entry['st'] = stack;
    }

    _ring.add(entry);
    while (_ring.length > _ringCapacity) {
      _ring.removeAt(0);
    }
  }

  /// Bearer tokens must never leave the device in a dump.
  String _redact(String text) => text.replaceAll(
    RegExp(r'bearer\s+[A-Za-z0-9%+/=._-]+', caseSensitive: false),
    'Bearer <redacted>',
  );

  void _announce(String message) {
    debugPrint('QUAX-BRIDGE: $message');
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      final response = await _handle(request);
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    } catch (e, stackTrace) {
      event(
        'debug.bridge',
        'request ${request.uri} failed: $e',
        error: e,
        stackTrace: stackTrace,
      );
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': e.toString()}));
      await request.response.close();
    }
  }

  Future<Map<String, dynamic>> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final query = request.uri.queryParameters;
    final since = int.tryParse(query['since'] ?? '') ?? -1;

    switch (path) {
      case '/':
        return {
          'bridge': 'quax debug bridge',
          'endpoints': ['/ping', '/dump', '/logs?since=N', '/prefs', '/db'],
        };
      case '/ping':
        return {'ok': true, 'port': _port, 'version': _version};
      case '/dump':
        return await snapshot();
      case '/logs':
        return {'since': since, 'records': logs(since: since)};
      case '/prefs':
        return {'prefs': _prefSection()};
      case '/db':
        return await _databaseSection();
      default:
        throw StateError('unknown endpoint $path');
    }
  }

  /// Log records newer than [since], oldest first.
  List<Map<String, dynamic>> logs({int since = -1}) =>
      _ring.where((entry) => (entry['n'] as int) > since).toList();

  /// The whole document an agent needs to reason about the app state. Each
  /// section is isolated: a broken database must still produce a dump with
  /// the logs and account health intact — that is when they matter most.
  Future<Map<String, dynamic>> snapshot() async {
    final now = DateTime.now();

    return {
      'at': now.toIso8601String(),
      'port': _port,
      'app': {
        'version': _version,
        'mode': kDebugMode
            ? 'debug'
            : kProfileMode
            ? 'profile'
            : 'release',
        'platform': Platform.operatingSystemVersion,
      },
      'database': await _guard(_databaseSection),
      'accounts': await _guard(_accountsSection),
      'rateLimits': RateLimitTracker.snapshot(now),
      'downloads': await _guard(_downloadsSection),
      'videoCache': await _guard(_videoCacheSection),
      'freshness': await _guard(_freshnessSection),
      'cachedTweets': await _guard(_cachedTweetsSection),
      'logs': logs(),
    };
  }

  /// Keeps a failing section out of the way of the rest of the dump.
  Future<Object?> _guard(Future<Object?> Function() build) async {
    try {
      return await build();
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _databaseSection() async {
    final sqlite.Database database = await Repository.readOnly();
    final version = await database.getVersion();
    final tables = <String, int>{};
    for (final table in const [
      tableSubscription,
      tableSubscriptionGroup,
      tableSubscriptionGroupMember,
      tableSearchSubscription,
      tableSearchSubscriptionGroupMember,
      tableSavedTweet,
      tableSavedTweetFolder,
      tableLikedTweet,
      tableFeedGroupChunk,
      tableFeedGroupCursor,
      tableAccounts,
    ]) {
      final count = await database.rawQuery('SELECT COUNT(*) AS c FROM $table');
      tables[table] = _countOf(count);
    }
    // The handle is the shared single instance: never closed here.
    return {'version': version, 'tables': tables};
  }

  int _countOf(List<Map<String, Object?>> rows) {
    final value = rows.isEmpty ? null : rows.first['c'];
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<List<Map<String, dynamic>>> _accountsSection() async {
    // Deliberately excluding authHeader: the stored session data never leaves
    // the device through this bridge.
    final accounts = await getAccounts();
    return [
      for (final account in accounts)
        {
          'id': account.id,
          'screenName': account.screenName,
          'isActive': account.isActive,
          'consecutiveNotFound': account.consecutiveNotFound,
          'lastNotFoundAt': account.lastNotFoundAt,
        },
    ];
  }

  Future<List<Map<String, dynamic>>> _downloadsSection() async => [
    for (final item in DownloadsModel().state)
      {
        'fileName': item.fileName,
        'status': item.status.name,
        'receivedBytes': item.receivedBytes,
        'totalBytes': item.totalBytes,
        'speedMbPerSec': item.speedMbPerSec,
        'error': item.error,
      },
  ];

  Future<Map<String, dynamic>> _videoCacheSection() async {
    final cache = VideoCache();
    return {'count': cache.count, 'totalBytes': cache.totalBytes};
  }

  Future<Map<String, dynamic>> _freshnessSection() async {
    final index = TweetFreshnessIndex();
    return {'loaded': index.isLoaded};
  }

  /// The always-new home's archive, per source: lets an agent verify that an
  /// empty home tab is genuinely "everything is archived", not a filter bug.
  Future<Map<String, dynamic>> _cachedTweetsSection() async {
    final bySource = await CachedTweetModel().counts();
    return {
      'sources': bySource,
      'total': bySource.values.fold(0, (a, b) => a + b),
    };
  }

  Map<String, dynamic> _prefSection() {
    final prefs = _prefs;
    if (prefs == null) {
      return {};
    }
    final values = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      try {
        values[key] = prefs.get<dynamic>(key);
      } catch (_) {
        values[key] = '<unreadable>';
      }
    }
    return values;
  }
}
