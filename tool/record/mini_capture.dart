// ignore_for_file: avoid_print
//
// Focused capture: opens ONE url in an already-running Chrome (debug port 9222)
// and writes every GraphQL response it sees under test/fixtures/<Operation>/,
// with NO pruning. Made because a full capture run can be rate-limited and end
// up deleting undamaged fixtures. Run:
//
//   dart run tool/record/mini_capture.dart https://x.com/notifications

import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:puppeteer/puppeteer.dart';

const _port = 9222;
const _pageTimeout = Duration(seconds: 20);
const _bodyTimeout = Duration(seconds: 10);
const _drainTimeout = Duration(seconds: 10);
const _quiet = Duration(milliseconds: 1200);
const _settleCap = Duration(seconds: 8);

final _outDir = Directory('test/fixtures');
final _graphql = RegExp(r'/i/api/graphql/([\w-]+)/(\w+)');

const _keepHeaders = {
  'content-type',
  'x-rate-limit-limit',
  'x-rate-limit-remaining',
  'x-rate-limit-reset',
};

final _secrets = <RegExp, String>{
  RegExp(r'\bauth_token\b'): 'session cookie',
  RegExp(r'\bct0\b'): 'CSRF cookie',
  RegExp(r'Bearer\s+AAAA', caseSensitive: false): 'bearer token',
  RegExp(r'\bset-cookie\b', caseSensitive: false): 'Set-Cookie header',
};

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty ? args.first : 'https://x.com/notifications';

  final browser =
      await puppeteer.connect(browserUrl: 'http://localhost:$_port', defaultViewport: null);
  // A fresh tab: an existing one may already sit on the same url, where a goto
  // is a no-op and everything was fetched before our listener attached.
  final page = await browser.newPage();

  final captured = <String, Map<String, dynamic>>{};
  final pending = <Future<void>>[];
  var lastSeen = DateTime.now();

  final subscription = page.onResponse.listen((response) {
    final match = _graphql.firstMatch(response.url);
    if (match == null) return;
    lastSeen = DateTime.now();
    pending.add(_collect(response, url, captured).catchError((Object error) {
      print('  skipped a response: $error');
    }));
  });

  try {
    await page.goto(url, wait: Until.domContentLoaded, timeout: _pageTimeout);
  } on Exception catch (error) {
    print('could not load $url: $error');
  }

  for (var scroll = 0; scroll < 4; scroll++) {
    await _settle(() => lastSeen);
    try {
      await page.evaluate('() => window.scrollBy(0, document.body.scrollHeight)');
    } on Exception {
      break;
    }
  }
  await _settle(() => lastSeen);

  await Future.wait(pending).timeout(_drainTimeout, onTimeout: () => <void>[]);
  await subscription.cancel();

  var written = 0;
  for (final fixture in captured.values) {
    final text = const JsonEncoder.withIndent(' ').convert(fixture);
    final leak = _secrets.entries.firstWhereOrNull((e) => e.key.hasMatch(text));
    if (leak != null) {
      print('  skipped ${fixture['operation']} — contains a ${leak.value}');
      continue;
    }

    final variables = jsonEncode(fixture['variables']);
    final digest = (variables.hashCode & 0xffffff).toRadixString(16);
    final path =
        '${_outDir.path}/${fixture['operation']}/mini-$digest.json';
    final file = File(path);
    final existed = file.existsSync();
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('$text\n');
    print('  ${existed ? 'updated' : 'new    '} $path  [${fixture['status']}]');
    written++;
  }

  print('\n$written fixture(s) written — no pruning happened.');
  browser.disconnect();
}

Future<void> _collect(
  Response response,
  String sourceUrl,
  Map<String, Map<String, dynamic>> into,
) async {
  final match = _graphql.firstMatch(response.url)!;
  final uri = Uri.parse(response.url);
  final String body;
  try {
    body = await response.text.timeout(_bodyTimeout);
  } on Exception {
    return;
  }

  final operation = match.group(2)!;
  print('  <- $operation');

  into['$operation|${uri.queryParameters['variables']}'] = {
    'scenario': 'Captured from $sourceUrl',
    'sourceUrl': sourceUrl,
    'operation': operation,
    'host': uri.host,
    'queryId': match.group(1),
    'features': _decode(uri.queryParameters['features']),
    'fieldToggles': _decode(uri.queryParameters['fieldToggles']),
    'variables': _decode(uri.queryParameters['variables']),
    'status': response.status,
    'headers': {
      for (final entry in response.headers.entries)
        if (_keepHeaders.contains(entry.key.toLowerCase())) entry.key.toLowerCase(): entry.value,
    },
    'body': _decode(body) ?? body,
  };
}

dynamic _decode(String? raw) {
  if (raw == null) return null;
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}

Future<void> _settle(DateTime Function() lastSeen) async {
  final deadline = DateTime.now().add(_settleCap);
  while (DateTime.now().isBefore(deadline)) {
    if (DateTime.now().difference(lastSeen()) > _quiet) return;
    await Future.delayed(Duration(milliseconds: 250));
  }
}
