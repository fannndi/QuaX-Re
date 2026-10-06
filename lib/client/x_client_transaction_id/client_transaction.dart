import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import 'package:quax/client/http_client.dart';

import 'constants.dart';
import 'cubic_curve.dart';
import 'interpolate.dart';
import 'rotation.dart';
import 'utils.dart';

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

  /// Fetches x.com and initializes the transaction ID generator.
  static Future<ClientTransaction> initialize({
    String randomKeyword = defaultKeyword,
    int randomNumber = additionalRandomNumber,
  }) async {
    final homePageResponse = await http.get(
      Uri.https('x.com', '/home'),
      headers: {
        'Accept-Language': 'en-US,en;q=0.9',
        'Cache-Control': 'no-cache',
        'Referer': 'https://x.com',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36',
        'X-Twitter-Active-User': 'yes',
        'X-Twitter-Client-Language': 'en',
      },
    );
    final homePageHtml = homePageResponse.body;
    final homePageDoc = html_parser.parse(homePageHtml);

    final indicesUrl = await _findIndicesFileUrl(homePageHtml);
    final indicesResponse = await quaxHttpClient.get(Uri.parse(indicesUrl));
    final indicesText = indicesResponse.body;

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
    final element =
        doc.querySelector("meta[name='twitter-site-verification']");
    if (element == null) {
      throw Exception(
          "Couldn't get [twitter-site-verification] key from the page source");
    }
    return element.attributes['content']!;
  }

  static List<int> _getKeyBytes(String key) => base64.decode(key).toList();

  /// The URL of the file holding the animation indices.
  ///
  /// The legacy frontend linked it straight from the page as
  /// `ondemand.s.<hash>a.js`, so one regex over the HTML found it. The x-web
  /// build does not link it at all: the page carries a single entry bundle, that
  /// bundle imports the asset chunks, and one of them —
  /// `assets/sentry-filter-*.js` — is what imports `./sign.o-*.js`. So the
  /// search walks from the page into the chunks, in waves, and stops at the
  /// first file that names it. The legacy path is tried first, so a page that
  /// still uses it costs one request instead of eighty.
  static Future<String> _findIndicesFileUrl(String html) async {
    final legacy = onDemandFileRegex.firstMatch(html);
    if (legacy != null) {
      final fileIndex = legacy.group(1)!;
      final hashMatch =
          RegExp(',${RegExp.escape(fileIndex)}:"([0-9a-f]+)"').firstMatch(html);
      if (hashMatch == null) throw Exception("Couldn't find ondemand file hash");
      return onDemandFileUrlTemplate.replaceAll('{filename}', hashMatch.group(1)!);
    }

    final entries =
        xWebEntryScriptRegex.allMatches(html).map((m) => m.group(0)!).toSet().toList();
    if (entries.isEmpty) throw Exception("Couldn't find the x-web entry script");

    for (final entry in entries) {
      final entryUri = Uri.parse(entry);
      final String entryBody;
      try {
        entryBody = await quaxHttpClient.read(entryUri);
      } catch (_) {
        continue;
      }

      final chunks = xWebChunkRegex
          .allMatches(entryBody)
          .map((m) => entryUri.resolve(m.group(1)!))
          .toSet()
          .toList();

      final indices = await _indicesFileAmong(chunks);
      if (indices != null) return indices.toString();
    }

    throw Exception("Couldn't find ondemand file index");
  }

  /// The first of [chunks] whose body names the indices file, resolved against
  /// that chunk's own URL. Fetched a wave at a time rather than all at once: a
  /// wave is normally enough, and the whole walk has to finish inside the
  /// caller's timeout.
  static Future<Uri?> _indicesFileAmong(List<Uri> chunks) async {
    const wave = 16;

    for (var start = 0; start < chunks.length; start += wave) {
      final slice = chunks.sublist(start, start + wave <= chunks.length ? start + wave : chunks.length);
      final bodies = await Future.wait(slice.map((uri) async {
        try {
          return await quaxHttpClient.read(uri);
        } catch (_) {
          // A chunk that 404s or fails to decode simply is not the one we want.
          return '';
        }
      }));

      for (var i = 0; i < bodies.length; i++) {
        final match = indicesFileRegex.firstMatch(bodies[i]);
        if (match != null) return slice[i].resolve(match.group(0)!);
      }
    }

    return null;
  }

  static List<List<int>> _get2dArray(
      List<int> keyBytes, html_dom.Document doc) {
    final frames = doc.querySelectorAll('[id^="loading-x-anim"]');
    final frame = frames[keyBytes[5] % 4];
    final pathElement = frame.children[0].children[1];
    final d = pathElement.attributes['d']!.substring(9);
    return d
        .split('C')
        .map((segment) {
          final cleaned = segment.replaceAll(RegExp(r'[^\d]+'), ' ').trim();
          if (cleaned.isEmpty) return <int>[];
          return cleaned
              .split(RegExp(r'\s+'))
              .where((s) => s.isNotEmpty)
              .map(int.parse)
              .toList();
        })
        .where((row) => row.isNotEmpty)
        .toList();
  }

  static double _solve(
      double value, double minVal, double maxVal, bool rounding) {
    final result = value * (maxVal - minVal) / 255.0 + minVal;
    return rounding ? result.floor().toDouble() : roundTo2(result);
  }

  static String _animate(List<int> frames, double targetTime) {
    final fromColor = [
      frames[0].toDouble(), frames[1].toDouble(),
      frames[2].toDouble(), 1.0,
    ];
    final toColor = [
      frames[3].toDouble(), frames[4].toDouble(),
      frames[5].toDouble(), 1.0,
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
    const totalTime = 4096;
    final frameRowIndex = keyBytes[rowIndex] % 16;
    final frameTimeProduct = keyBytesIndices
        .fold<int>(1, (acc, idx) => acc * (keyBytes[idx] % 16));
    final frameTime = jsRound(frameTimeProduct / 10.0) * 10;

    final arr = _get2dArray(keyBytes, homePageDoc);
    final frameRow = arr[frameRowIndex];
    final targetTime = frameTime / totalTime;
    return _animate(frameRow, targetTime.toDouble());
  }
}
