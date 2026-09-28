import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pref/pref.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/utils/debug_bridge.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await deleteDatabase(databaseName);
    await Repository().migrate();
  });

  tearDown(() async {
    await DebugBridge().stopForTests();
  });

  group('DebugBridge ring buffer', () {
    test('Should stay bounded and keep the newest records', () {
      final bridge = DebugBridge();
      for (var i = 0; i < 300; i++) {
        bridge.record(LogRecord(Level.INFO, 'msg $i', 'test'));
      }

      final logs = bridge.logs();
      expect(
        logs.length,
        250,
        reason: 'An unbounded ring would grow with every feed refresh over a long session',
      );
      expect(
        logs.last['m'],
        'msg 299',
        reason: 'The newest record is the one an agent needs most',
      );
      expect(
        (logs.first['n'] as int) < (logs.last['n'] as int),
        isTrue,
        reason: 'Records keep their order, so since-filtering works',
      );
    });

    test('Should return only the records newer than the given sequence', () {
      final bridge = DebugBridge();
      for (var i = 0; i < 20; i++) {
        bridge.record(LogRecord(Level.INFO, 'msg $i', 'test'));
      }

      final newer = bridge.logs(since: 14);
      expect(
        newer.first['m'],
        'msg 15',
        reason:
            'since=N means "everything after N", the cursor the agent keeps',
      );
      expect(newer.length, 5, reason: 'Exactly the five records after 14');
      expect(
        bridge.logs(since: 19).length,
        0,
        reason: 'Nothing is newer than the newest record',
      );
    });

    test('Should redact bearer tokens out of the ring', () {
      final bridge = DebugBridge();
      bridge.event('test', 'sent Authorization: Bearer AAAAsecretTOKEN123 ok');

      final logs = bridge.logs();
      final message = logs.last['m'] as String;
      expect(
        message.contains('AAAAsecretTOKEN123'),
        isFalse,
        reason: 'A dump must be shareable with an agent without leaking the session',
      );
      expect(
        message.contains('Bearer <redacted>'),
        isTrue,
        reason: 'The redaction should be visible, not a silent drop',
      );
    });
  });

  group('DebugBridge HTTP surface', () {
    late int port;

    setUp(() async {
      // flutter_test installs a global HttpOverrides that mocks client
      // connections; the loopback bridge must be reachable as really bound.
      HttpOverrides.global = null;
      await DebugBridge().start(
        PrefServiceCache(),
        firstPort: 18642,
        lastPort: 18652,
      );
      port = DebugBridge().port;
      expect(
        port,
        greaterThan(0),
        reason: 'The test range 18642-18652 must have a free port',
      );
    });

    Future<Map<String, dynamic>> get(String path) async {
      final client = HttpClient();
      final response = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port$path'))
          .then((request) => request.close());
      final body = await response.transform(utf8.decoder).join();
      client.close();
      return {'status': response.statusCode, 'body': body};
    }

    test('Should answer ping with the running port', () async {
      final result = await get('/ping');
      final json = jsonDecode(result['body'] as String) as Map<String, dynamic>;

      expect(result['status'], 200, reason: 'A live bridge answers 200');
      expect(json['ok'], isTrue, reason: 'ping is the liveness check');
      expect(
        json['port'],
        port,
        reason: 'The probe learns the port from here via logcat',
      );
    });

    test('Should serve a dump that never contains an auth header', () async {
      final result = await get('/dump');
      final json = jsonDecode(result['body'] as String) as Map<String, dynamic>;

      expect(
        result['status'],
        200,
        reason: 'The dump endpoint is the main surface',
      );
      expect(
        json['accounts'],
        isA<List>(),
        reason: 'Account health is what the agent reasons about first',
      );
      expect(
        result['body']!.contains('authHeader'),
        isFalse,
        reason: 'The stored session data must never leave the device',
      );
      expect(
        json['database'],
        isA<Map>(),
        reason: 'The schema version tells the agent which migrations ran',
      );
      expect(
        json['logs'],
        isA<List>(),
        reason: 'The log ring is part of the dump',
      );
    });

    test(
      'Should answer an unknown endpoint with a 500 and an error document',
      () async {
        final result = await get('/nope');

        expect(
          result['status'],
          500,
          reason: 'A typo in the agent command must be visible, not hang',
        );
        expect(
          (jsonDecode(result['body'] as String) as Map)['error'],
          isA<String>(),
          reason:
              'The error message is how the agent learns the correct endpoint',
        );
      },
    );

    test('Should serve the preference values', () async {
      final result = await get('/prefs');
      final json = jsonDecode(result['body'] as String) as Map<String, dynamic>;

      expect(
        json['prefs'],
        isA<Map>(),
        reason: 'Preferences drive most behavior the agent may want to inspect',
      );
    });
  });
}
