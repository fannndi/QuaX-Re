import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

enum VaultFailure { weakPassphrase, wrongPassphrase, corrupt, unsupportedVersion, tooLarge }

class VaultException implements Exception {
  final VaultFailure failure;

  const VaultException(this.failure);

  @override
  String toString() => 'VaultException(${failure.name})';
}

/// Versioned, passphrase-protected envelope used by both the account and the
/// local-likes backups.
///
/// AES-256-GCM supplies confidentiality and integrity; PBKDF2-HMAC-SHA256 turns
/// the passphrase into the key. The KDF parameters and nonce are authenticated
/// as additional data, so an edited iteration count or salt cannot silently
/// weaken the next decryption.
class VaultCodec {
  const VaultCodec({
    this.iterations = 210000,
    this.maxEnvelopeLength = 8 * 1024 * 1024,
    this.minimumIterations = 10000,
    this.maximumIterations = 2000000,
    this.random,
  });

  final int iterations;
  final int maxEnvelopeLength;
  final int minimumIterations;
  final int maximumIterations;
  final Random? random;

  static const format = 'quax.vault';
  static const currentVersion = 1;
  static const _kdfAlgorithm = 'pbkdf2-hmac-sha256';
  static const _cipherAlgorithm = 'aes-256-gcm';
  static const _minPassphraseLength = 8;

  Future<String> encrypt({
    required String passphrase,
    required String kind,
    required Map<String, dynamic> payload,
  }) {
    return encryptBytes(
      passphrase: passphrase,
      kind: kind,
      bytes: utf8.encode(jsonEncode(payload)),
    );
  }

  /// Encrypts arbitrary bytes. The local-likes backup uses this for its
  /// gzipped NDJSON stream, avoiding a second base64 copy of the whole file.
  Future<String> encryptBytes({
    required String passphrase,
    required String kind,
    required List<int> bytes,
  }) async {
    _checkPassphrase(passphrase);
    if (kind.isEmpty) throw const VaultException(VaultFailure.corrupt);
    if (iterations < minimumIterations || iterations > maximumIterations) {
      throw const VaultException(VaultFailure.corrupt);
    }

    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);
    final key = await _deriveKey(passphrase, salt, iterations);
    try {
      final box = await AesGcm.with256bits().encrypt(
        bytes,
        secretKey: key,
        nonce: nonce,
        aad: _aad(currentVersion, kind, salt, nonce, iterations),
      );
      final envelope = <String, dynamic>{
        'format': format,
        'version': currentVersion,
        'kind': kind,
        'kdf': {
          'algorithm': _kdfAlgorithm,
          'iterations': iterations,
          'salt': base64Encode(salt),
        },
        'cipher': {
          'algorithm': _cipherAlgorithm,
          'nonce': base64Encode(nonce),
        },
        'payload': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      };
      final text = jsonEncode(envelope);
      if (text.length > maxEnvelopeLength) throw const VaultException(VaultFailure.tooLarge);
      return text;
    } finally {
      key.destroy();
    }
  }

  Future<Map<String, dynamic>> decrypt({
    required String passphrase,
    required String kind,
    required String envelope,
  }) async {
    final bytes = await decryptBytes(passphrase: passphrase, kind: kind, envelope: envelope);
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const VaultException(VaultFailure.corrupt);
      }
      return decoded;
    } on FormatException {
      throw const VaultException(VaultFailure.corrupt);
    }
  }

  Future<Uint8List> decryptBytes({
    required String passphrase,
    required String kind,
    required String envelope,
  }) async {
    _checkPassphrase(passphrase);
    if (envelope.length > maxEnvelopeLength) throw const VaultException(VaultFailure.tooLarge);

    final parsed = _parseEnvelope(envelope);
    if (parsed['format'] != format || parsed['kind'] != kind) {
      throw const VaultException(VaultFailure.corrupt);
    }
    final version = parsed['version'];
    if (version is! int || version < 1) throw const VaultException(VaultFailure.corrupt);
    if (version > currentVersion) throw const VaultException(VaultFailure.unsupportedVersion);

    final (salt, nonce, iterations) = _readParameters(parsed);
    final cipherText = _decodeBytes(parsed['payload']);
    final mac = _decodeBytes(parsed['mac']);
    if (cipherText.isEmpty || mac.length != 16) {
      throw const VaultException(VaultFailure.corrupt);
    }

    final key = await _deriveKey(passphrase, salt, iterations);
    try {
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
        aad: _aad(version, kind, salt, nonce, iterations),
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const VaultException(VaultFailure.wrongPassphrase);
    } finally {
      key.destroy();
    }
  }

  Map<String, dynamic> _parseEnvelope(String envelope) {
    try {
      final decoded = jsonDecode(envelope);
      if (decoded is! Map<String, dynamic>) throw const VaultException(VaultFailure.corrupt);
      return decoded;
    } on FormatException {
      throw const VaultException(VaultFailure.corrupt);
    }
  }

  (Uint8List, Uint8List, int) _readParameters(Map<String, dynamic> envelope) {
    final kdf = envelope['kdf'];
    final cipher = envelope['cipher'];
    if (kdf is! Map || cipher is! Map) throw const VaultException(VaultFailure.corrupt);
    if (kdf['algorithm'] != _kdfAlgorithm || cipher['algorithm'] != _cipherAlgorithm) {
      throw const VaultException(VaultFailure.corrupt);
    }

    final iterations = kdf['iterations'];
    if (iterations is! int ||
        iterations < minimumIterations ||
        iterations > maximumIterations) {
      throw const VaultException(VaultFailure.corrupt);
    }

    final salt = _decodeBytes(kdf['salt']);
    final nonce = _decodeBytes(cipher['nonce']);
    if (salt.length < 16 || nonce.length != 12) {
      throw const VaultException(VaultFailure.corrupt);
    }
    return (salt, nonce, iterations);
  }

  Uint8List _decodeBytes(Object? value) {
    if (value is! String || value.isEmpty) throw const VaultException(VaultFailure.corrupt);
    try {
      return base64Decode(value);
    } on FormatException {
      throw const VaultException(VaultFailure.corrupt);
    }
  }

  Uint8List _randomBytes(int length) {
    final source = random ?? Random.secure();
    return Uint8List.fromList(List<int>.generate(length, (_) => source.nextInt(256)));
  }

  void _checkPassphrase(String passphrase) {
    if (passphrase.trim().length < _minPassphraseLength) {
      throw const VaultException(VaultFailure.weakPassphrase);
    }
  }

  Future<SecretKey> _deriveKey(String passphrase, Uint8List salt, int iterations) async {
    // The KDF is the expensive part (hundreds of thousands of HMAC rounds).
    // Running it off the UI isolate keeps the passphrase dialog responsive.
    final bytes = await Isolate.run(() => _deriveKeyBytes(passphrase.trim(), salt, iterations));
    return SecretKeyData(bytes);
  }

  List<int> _aad(
      int version, String kind, Uint8List salt, Uint8List nonce, int iterations) {
    return utf8.encode([
      format,
      '$version',
      kind,
      _kdfAlgorithm,
      '$iterations',
      base64Encode(salt),
      _cipherAlgorithm,
      base64Encode(nonce),
    ].join('\u0000'));
  }
}

Future<Uint8List> _deriveKeyBytes(String passphrase, Uint8List salt, int iterations) async {
  final pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);
  final key = await pbkdf2.deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);
  final bytes = await key.extractBytes();
  // extractBytes returns a view over the sensitive buffer; copy before
  // destroy() zeroes it.
  final copy = Uint8List.fromList(bytes);
  key.destroy();
  return copy;
}
