import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;

import 'package:quax/client/http_client.dart';

import 'constants.dart';
import 'cubic_curve.dart';
import 'interpolate.dart';
import 'rotation.dart';
import 'utils.dart';

typedef TransactionReader = Future<String> Function(
  Uri uri, {
  Future<void>? abortTrigger,
});

const _defaultDiscoveryTimeout = Duration(seconds: 15);

class ClientTransaction {
  final List<int> _keyBytes;
  final String _animationKey;
  final String _randomKeyword;
  final int _randomNumber;

  ClientTransaction._({
    required this._keyBytes,
    required this._animationKey,
    required this._randomKeyword,
    required this._randomNumber,
  });

  /// Fetches x.com and initializes the transaction ID generator. [reader] is the
  /// HTTP boundary used for both the page and its imported bundles; production
  /// supplies abortable requests, while fixture tests can replay a build graph.
  /// [deadline] bounds the whole derivation and is forwarded to every read.
  static Future<ClientTransaction> initialize({
    String randomKeyword = defaultKeyword,
    int randomNumber = additionalRandomNumber,
    TransactionReader? reader,
    int maxDepth = 6,
    int requestBudget = 64,
    Duration assetTimeout = const Duration(seconds: 5),
    DateTime? deadline,
  }) async {
    if (maxDepth < 0 || requestBudget < 1) {
      throw ArgumentError('Discovery bounds must allow at least the home page');
    }
    final effectiveDeadline =
        deadline ?? DateTime.now().add(_defaultDiscoveryTimeout);
    final abort = Completer<void>();
    final remaining = effectiveDeadline.difference(DateTime.now());
    final timer = remaining.isNegative
        ? null
        : Timer(remaining, () => _completeAbort(abort));
    if (remaining.isNegative) _completeAbort(abort);

    final TransactionReader read = reader ?? _readProduction;
    Future<String> readRequired(Uri uri) async {
      _checkDeadline(abort);
      try {
        final body = await read(
          uri,
          abortTrigger: abort.future,
        ).timeout(effectiveDeadline.difference(DateTime.now()));
        _checkDeadline(abort);
        return body;
      } on TimeoutException {
        if (!abort.isCompleted) _completeAbort(abort);
        rethrow;
      }
    }

    try {
      final homePageHtml = await readRequired(Uri.https('x.com', '/home'));
      final homePageDoc = html_parser.parse(homePageHtml);

      final discovery = await _findIndicesFileUrl(
        homePageHtml,
        read: read,
        maxDepth: maxDepth,
        requestBudget: requestBudget - 1,
        assetTimeout: assetTimeout,
        abort: abort,
      );
      _checkDeadline(abort);
      if (discovery.requests >= requestBudget - 1) {
        throw Exception(
          'Discovery request budget exhausted before the indices file could be read',
        );
      }
      final indicesText = await readRequired(Uri.parse(discovery.url));

      final (rowIndex, keyBytesIndices) = _getIndices(indicesText);
      final key = _getKey(homePageDoc);
      final keyBytes = _getKeyBytes(key);
      final animationKey = _computeAnimationKey(
        keyBytes: keyBytes,
        rowIndex: rowIndex,
        keyBytesIndices: keyBytesIndices,
        homePageDoc: homePageDoc,
      );

      return ClientTransaction._(
        keyBytes: keyBytes,
        animationKey: animationKey,
        randomKeyword: randomKeyword,
        randomNumber: randomNumber,
      );
    } finally {
      timer?.cancel();
    }
  }

  static Future<String> _readProduction(
    Uri uri, {
    Future<void>? abortTrigger,
  }) async {
    return quaxHttpClient.readWithAbort(
      uri,
      abortTrigger: abortTrigger,
      headers: uri.host == 'x.com' && uri.path == '/home'
          ? {
              'Accept-Language': 'en-US,en;q=0.9',
              'Cache-Control': 'no-cache',
              'Referer': 'https://x.com',
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36',
              'X-Twitter-Active-User': 'yes',
              'X-Twitter-Client-Language': 'en',
            }
          : null,
    );
  }

  static void _checkDeadline(Completer<void> abort) {
    if (abort.isCompleted) {
      throw TimeoutException('Transaction discovery timed out');
    }
  }

  static void _completeAbort(Completer<void> abort) {
    if (abort.isCompleted) return;
    try {
      abort.complete();
    } on StateError {
      // A timeout and a wave cancellation can converge on the same trigger.
    }
  }

  /// Generates the x-client-transaction-id for the given HTTP method and path.
  String generateTransactionId(String method, String path) {
    final timeNow =
        (DateTime.now().millisecondsSinceEpoch - 1682924400 * 1000) ~/ 1000;
    final timeNowBytes = List.generate(4, (i) => (timeNow >> (i * 8)) & 0xFF);

    final hashInput = '$method!$path!$timeNow$_randomKeyword$_animationKey';
    final hashBytes = sha256.convert(utf8.encode(hashInput)).bytes;

    final randomNum = Random().nextInt(256);
    final bytesArr = [
      ..._keyBytes,
      ...timeNowBytes,
      ...hashBytes.take(16),
      _randomNumber,
    ];
    final out = Uint8List(bytesArr.length + 1);
    out[0] = randomNum;
    for (int i = 0; i < bytesArr.length; i++) {
      out[i + 1] = bytesArr[i] ^ randomNum;
    }

    return base64.encode(out).replaceAll('=', '');
  }

  // --- Private helpers (static, mirroring Python class methods) ---

  static (int, List<int>) _getIndices(String indicesFileText) {
    final indices = indicesRegex
        .allMatches(indicesFileText)
        .map((m) => int.parse(m.group(2)!))
        .toList();
    if (indices.isEmpty) throw Exception("Couldn't get KEY_BYTE indices");
    return (indices[0], indices.sublist(1));
  }

  static String _getKey(html_dom.Document doc) {
    final element = doc.querySelector("meta[name='twitter-site-verification']");
    if (element == null) {
      throw Exception(
        "Couldn't get [twitter-site-verification] key from the page source",
      );
    }
    return element.attributes['content']!;
  }

  static List<int> _getKeyBytes(String key) => base64.decode(key).toList();

  /// The URL of the file holding the animation indices.
  ///
  /// Legacy pages name `ondemand.s.<hash>a.js` directly. Named x-web references
  /// (`sign.o-*.js`) remain the fast path. Hashed builds expose no filename, so
  /// discovery follows at most two static import levels and inspects lazy
  /// `import(path).then(module => module.default())` candidates for signing
  /// content. Every wave is bounded, concurrent, and stops at the first hit.
  static Future<({String url, int requests})> _findIndicesFileUrl(
    String html, {
    required TransactionReader read,
    required int maxDepth,
    required int requestBudget,
    required Duration assetTimeout,
    required Completer<void> abort,
  }) async {
    final legacy = onDemandFileRegex.firstMatch(html);
    if (legacy != null) {
      final fileIndex = legacy.group(1)!;
      final hashMatch = RegExp(',${RegExp.escape(fileIndex)}:"([0-9a-f]+)"')
          .firstMatch(html);
      if (hashMatch == null) {
        throw Exception("Couldn't find ondemand file hash");
      }
      return (
        url: onDemandFileUrlTemplate.replaceAll(
          '{filename}',
          hashMatch.group(1)!,
        ),
        requests: 0,
      );
    }

    final entries = xWebEntryScriptRegex
        .allMatches(html)
        .map((match) => Uri.parse(match.group(0)!))
        .toSet();
    if (entries.isEmpty) {
      throw Exception("Couldn't find the x-web entry script");
    }

    final seen = <String>{for (final entry in entries) entry.toString()};
    var importedAssets = 0;
    var requests = 0;
    var level = entries.toList();

    for (var depth = 0; ; depth++) {
      _checkDeadline(abort);
      final affordable = level.take(requestBudget - requests).toList();
      if (affordable.isEmpty) break;
      requests += affordable.length;
      final scanned = await _scanAssets(affordable, read, assetTimeout, abort);
      if (scanned.namedUrl != null) {
        return (url: scanned.namedUrl!, requests: requests);
      }

      // Dynamic candidates are not filtered by [seen]: a modulepreload link may
      // already have fetched the signing chunk before we found its default import.
      _checkDeadline(abort);
      final candidates = _importLinks(
        scanned.bodies,
        defaultImportRegex,
      ).take(maxImportedAssets).take(requestBudget - requests).toList();
      if (candidates.isNotEmpty) {
        requests += candidates.length;
        final dynamic = await _scanAssets(
          candidates,
          read,
          assetTimeout,
          abort,
        );
        if (dynamic.namedUrl != null) {
          return (url: dynamic.namedUrl!, requests: requests);
        }
        for (final entry in dynamic.bodies.entries) {
          if (indicesRegex.allMatches(entry.value).length >= 2) {
            return (url: entry.key.toString(), requests: requests);
          }
        }
      }

      // Page entries are level zero. Follow at most two additional static levels
      // and at most 32 imported assets beyond those entries.
      if (depth >= maxStaticImportDepth || depth + 1 >= maxDepth) break;
      _checkDeadline(abort);
      final remainingAssets = maxImportedAssets - importedAssets;
      level = _importLinks(scanned.bodies, staticImportRegex)
          .where((uri) => !seen.contains(uri.toString()))
          .take(remainingAssets)
          .take(requestBudget - requests)
          .toList();
      importedAssets += level.length;
      seen.addAll(level.map((uri) => uri.toString()));
    }

    throw Exception("Couldn't find ondemand file index");
  }

  static Future<({String? namedUrl, Map<Uri, String> bodies})> _scanAssets(
    List<Uri> urls,
    TransactionReader read,
    Duration assetTimeout,
    Completer<void> abort,
  ) async {
    final waveAbort = Completer<void>();
    final abortSubscription = abort.future.asStream().listen((_) {
      _completeAbort(waveAbort);
    });
    final pending = <Uri, Future<({Uri uri, String? body})>>{
      for (final uri in urls)
        uri: _readAsset(uri, read, assetTimeout, waveAbort.future),
    };
    final bodies = <Uri, String>{};

    try {
      while (pending.isNotEmpty) {
        final result = await Future.any(pending.values);
        _checkDeadline(abort);
        pending.remove(result.uri);
        final body = result.body;
        if (body == null) continue;

        final named = indicesFileRegex.firstMatch(body);
        if (named != null) {
          return (
            namedUrl: result.uri.resolve(named.group(0)!).toString(),
            bodies: bodies,
          );
        }
        bodies[result.uri] = body;
      }
      return (namedUrl: null, bodies: bodies);
    } finally {
      // Cancelling the wave also aborts sibling HTTP reads after an early hit.
      if (pending.isNotEmpty) _completeAbort(waveAbort);
      await abortSubscription.cancel();
    }
  }

  static Future<({Uri uri, String? body})> _readAsset(
    Uri uri,
    TransactionReader read,
    Duration timeout,
    Future<void> waveAbort,
  ) async {
    final abort = Completer<void>();
    final timer = Timer(timeout, () => _completeAbort(abort));
    final subscription = waveAbort.asStream().listen((_) {
      _completeAbort(abort);
    });
    try {
      return (
        uri: uri,
        body: await read(uri, abortTrigger: abort.future).timeout(timeout),
      );
    } catch (_) {
      // The trigger above cancels production HTTP work; fixture readers may
      // simply ignore it, so the future timeout still bounds discovery.
      return (uri: uri, body: null);
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }

  static List<Uri> _importLinks(Map<Uri, String> bodies, RegExp pattern) {
    final links = <Uri>[];
    final seen = <String>{};
    for (final entry in bodies.entries) {
      for (final match in pattern.allMatches(entry.value)) {
        final uri = entry.key.resolve(match.group(2)!);
        if ((uri.scheme == 'https' || uri.scheme == 'http') &&
            seen.add(uri.toString())) {
          links.add(uri);
        }
      }
    }
    return links;
  }

  /// The 2-D frame array the animation key is derived from.
  ///
  /// Every index and parse here reads markup X owns and reshapes whenever they
  /// deploy, so each one is validated and a mismatch throws a descriptive
  /// [Exception] instead of a [RangeError]/[FormatException]. The caller
  /// (`TwitterHeaders`) already catches and backs off on a derivation failure —
  /// a readable message is what makes a 5-minute header outage diagnosable
  /// instead of a mystery.
  static List<List<int>> _get2dArray(
    List<int> keyBytes,
    html_dom.Document doc,
  ) {
    if (keyBytes.length < 6) {
      throw Exception(
        'site verification key is too short to index (${keyBytes.length} bytes)',
      );
    }

    final frames = doc.querySelectorAll('[id^="loading-x-anim"]');
    if (frames.isEmpty) {
      throw Exception('no loading-x-anim frames in the home page markup');
    }

    final frame = frames[keyBytes[5] % frames.length];
    final svg = frame.children.isEmpty ? null : frame.children[0];
    final paths = svg?.querySelectorAll('path') ?? const <html_dom.Element>[];
    final pathElement = paths.length > 1 ? paths[1] : null;
    final d = pathElement?.attributes['d'];
    if (d == null || d.length <= 9) {
      throw Exception('the loading animation frame carries no readable path');
    }

    return d
        .substring(9)
        .split('C')
        .map((segment) {
          final cleaned = segment.replaceAll(RegExp(r'[^\d]+'), ' ').trim();
          if (cleaned.isEmpty) return <int>[];
          // tryParse, not parse: a decimal or a negative coordinate (X's paths
          // do use them) would otherwise make the whole derivation fatal.
          return cleaned
              .split(RegExp(r'\s+'))
              .where((s) => s.isNotEmpty)
              .map(int.tryParse)
              .whereType<int>()
              .toList();
        })
        .where((row) => row.isNotEmpty)
        .toList();
  }

  static double _solve(
    double value,
    double minVal,
    double maxVal,
    bool rounding,
  ) {
    final result = value * (maxVal - minVal) / 255.0 + minVal;
    return rounding ? result.floor().toDouble() : roundTo2(result);
  }

  static String _animate(List<int> frames, double targetTime) {
    final fromColor = [
      frames[0].toDouble(),
      frames[1].toDouble(),
      frames[2].toDouble(),
      1.0,
    ];
    final toColor = [
      frames[3].toDouble(),
      frames[4].toDouble(),
      frames[5].toDouble(),
      1.0,
    ];
    final fromRotation = [0.0];
    final toRotation = [_solve(frames[6].toDouble(), 60.0, 360.0, true)];

    final framesTail = frames.sublist(7);
    final curves = framesTail
        .asMap()
        .entries
        .map((e) => _solve(e.value.toDouble(), isOdd(e.key), 1.0, false))
        .toList();

    final cubic = Cubic(curves);
    final val = cubic.getValue(targetTime);

    var color = interpolate(fromColor, toColor, val);
    color = color.map((v) => v.clamp(0.0, 255.0)).toList();

    final rotation = interpolate(fromRotation, toRotation, val);
    final matrix = convertRotationToMatrix(rotation[0]);

    final strArr = <String>[];
    for (int i = 0; i < color.length - 1; i++) {
      strArr.add(color[i].round().toRadixString(16));
    }
    for (final value in matrix) {
      double rounded = roundTo2(value);
      if (rounded < 0) rounded = -rounded;
      final hexValue = floatToHex(rounded);
      if (hexValue.startsWith('.')) {
        strArr.add('0$hexValue'.toLowerCase());
      } else if (hexValue.isNotEmpty) {
        strArr.add(hexValue);
      } else {
        strArr.add('0');
      }
    }
    strArr.addAll(['0', '0']);

    return strArr.join().replaceAll(RegExp(r'[.\-]'), '');
  }

  static String _computeAnimationKey({
    required List<int> keyBytes,
    required int rowIndex,
    required List<int> keyBytesIndices,
    required html_dom.Document homePageDoc,
  }) {
    // rowIndex and the indices come from a regex over a chunk X owns, and the
    // capture allows two digits — so an index up to 99 against a key that may
    // be shorter. Validate rather than RangeError.
    if (rowIndex < 0 || rowIndex >= keyBytes.length) {
      throw Exception(
        'animation key row index $rowIndex is outside the ${keyBytes.length}-byte key',
      );
    }
    if (keyBytesIndices.any((i) => i < 0 || i >= keyBytes.length)) {
      throw Exception(
        'animation key indices are outside the ${keyBytes.length}-byte key',
      );
    }
    if (keyBytesIndices.isEmpty) {
      throw Exception(
        'no animation key indices were found in the script chunk',
      );
    }

    const totalTime = 4096;
    final frameRowIndex = keyBytes[rowIndex] % 16;
    // The fold starts at 1, so an empty list would silently yield a wrong key
    // rather than an error — guarded above.
    final frameTimeProduct = keyBytesIndices.fold<int>(
      1,
      (acc, idx) => acc * (keyBytes[idx] % 16),
    );
    final frameTime = jsRound(frameTimeProduct / 10.0) * 10;

    final arr = _get2dArray(keyBytes, homePageDoc);
    if (frameRowIndex >= arr.length) {
      throw Exception(
        'the animation frame row $frameRowIndex is missing (only ${arr.length} rows)',
      );
    }
    final frameRow = arr[frameRowIndex];
    final targetTime = frameTime / totalTime;
    return _animate(frameRow, targetTime.toDouble());
  }
}
