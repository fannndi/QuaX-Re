// The host-side client of the in-app debug bridge (lib/utils/debug_bridge.dart).
//
// Usage: dart run tool/debug/probe.dart <command> [args]
//
// Commands:
//   dump                 one JSON document with the app's state snapshot
//   logs [since]         log records newer than sequence number since
//   prefs                current preference values
//   db                   database version and row counts
//   ping                 liveness check
//   help                 this text
//
// The app serves JSON on its loopback interface in debug/profile builds.
// This script finds the chosen port in logcat (tag prefix QUAX-BRIDGE),
// wires `adb reverse`, and reads the endpoint over plain HTTP — so it works
// with any debuggable build and needs no in-app UI.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final command = arguments.isEmpty ? 'help' : arguments[0];

  if (command == 'help') {
    stdout.writeln(_help);
    exit(0);
  }

  final adb = _findAdb();
  if (adb == null) {
    stderr.writeln(
      'adb not found. Install the Android SDK platform tools or set ANDROID_HOME.',
    );
    exit(1);
  }

  final serial = _serialFrom(arguments);
  final device = serial.isEmpty ? '' : '-s $serial ';

  // 1) Which loopback port did the app pick? (8642-8652, first free one)
  final port = await _bridgePort(adb, device);
  if (port == null) {
    stderr.writeln(
      'No "QUAX-BRIDGE port=" line in logcat. Is the app running in debug or profile mode?',
    );
    exit(1);
  }

  // 2) Tunnel a host port to the device loopback.
  final reversed = await _run('$adb ${device}reverse tcp:8642 tcp:$port');
  if (reversed.exitCode != 0) {
    stderr.writeln('adb reverse failed: ${reversed.stderr}');
    exit(1);
  }

  // 3) Read the endpoint.
  final path = switch (command) {
    'dump' => '/dump',
    'logs' => '/logs${arguments.length > 1 ? '?since=${arguments[1]}' : ''}',
    'prefs' => '/prefs',
    'db' => '/db',
    'ping' => '/ping',
    _ => '/unknown-$command',
  };

  try {
    final client = HttpClient();
    final response = await client
        .getUrl(Uri.parse('http://127.0.0.1:8642$path'))
        .then((request) => request.close());
    final body = await response.transform(utf8.decoder).join();
    client.close();

    if (response.statusCode != 200) {
      stderr.writeln('HTTP ${response.statusCode}: $body');
      exit(1);
    }
    // Pretty-print when possible so agents can read it straight away.
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(jsonDecode(body)),
    );
  } on SocketException catch (e) {
    stderr.writeln(
      'Cannot reach 127.0.0.1:8642 (adb reverse -> device port $port): $e',
    );
    stderr.writeln('Is the app in the foreground? Profile/debug builds only.');
    exit(1);
  }
}

const _help = '''
Usage: dart run tool/debug/probe.dart <command> [args]

Commands:
  dump                 one JSON document with the app's state snapshot
  logs [since]         log records newer than sequence number since
  prefs                current preference values
  db                   database version and row counts
  ping                 liveness check
  help                 this text

Options:
  --serial <id>        target a specific adb device/emulator
''';

String _serialFrom(List<String> arguments) {
  final index = arguments.indexOf('--serial');
  if (index != -1 && index + 1 < arguments.length) {
    return arguments[index + 1];
  }
  return '';
}

String? _findAdb() {
  final home = Platform.environment['HOME'] ?? '';
  final sdk =
      Platform.environment['ANDROID_HOME'] ??
      Platform.environment['ANDROID_SDK_ROOT'];
  final candidates = [
    if (sdk != null) '$sdk/platform-tools/adb',
    '$home/Android/Sdk/platform-tools/adb',
    'adb',
  ];
  for (final candidate in candidates) {
    if (candidate == 'adb') {
      return Process.runSync('adb', ['--version']).exitCode == 0 ? 'adb' : null;
    }
    final file = File(candidate);
    if (file.existsSync()) return candidate;
  }
  return null;
}

Future<int?> _bridgePort(String adb, String device) async {
  final logcat = await _run('$adb ${device}logcat -d');
  if (logcat.exitCode != 0) {
    stderr.writeln('adb logcat failed: ${logcat.stderr}');
    return null;
  }

  int? port;
  for (final line in logcat.stdout.toString().split('\n')) {
    final match = RegExp(r'QUAX-BRIDGE: port=(\d+)').firstMatch(line);
    if (match != null) {
      port = int.parse(match.group(1)!);
    }
  }
  return port;
}

Future<ProcessResult> _run(String command) async {
  return await Process.run('/bin/sh', ['-c', command]);
}
