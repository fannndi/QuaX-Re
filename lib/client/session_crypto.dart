import 'package:flutter/foundation.dart';
import 'package:quax/constants.dart';

typedef SessionCryptoOverride = Future<String> Function(
  String method,
  Map<String, dynamic> arguments,
);

/// Android Keystore-backed encryption for the session header at rest.
///
/// The prefix is part of the stored value, not a security boundary. It lets
/// older installs distinguish their plaintext `auth_header` rows from values
/// this version encrypted. Native code owns the key and treats the ciphertext
/// as opaque; it must return the same string from `decryptSession` that it
/// accepted from `encryptSession`. The Dart-only version prefix is stripped
/// before the ciphertext crosses the channel.
class SessionCrypto {
  const SessionCrypto();

  static const encryptedPrefix = 'quax.session.v1:';
  static SessionCryptoOverride? _debugOverride;

  @visibleForTesting
  static set debugOverride(SessionCryptoOverride? value) {
    assert(
      kDebugMode,
      'The session crypto override is only available in debug tests',
    );
    _debugOverride = value;
  }

  static bool isEncrypted(String value) => value.startsWith(encryptedPrefix);

  Future<String> encrypt(String plaintext) async {
    final result = await _call('encryptSession', plaintext);
    if (result.isEmpty) {
      throw StateError('Session encryption returned an empty value');
    }
    return isEncrypted(result) ? result : '$encryptedPrefix$result';
  }

  Future<String> decrypt(String ciphertext) async {
    if (!isEncrypted(ciphertext)) {
      throw ArgumentError('Session ciphertext is missing its version prefix');
    }
    return _call(
      'decryptSession',
      ciphertext.substring(encryptedPrefix.length),
    );
  }

  /// Reads both encrypted rows and the plaintext rows written by older builds.
  /// Callers may re-encrypt a legacy value after a successful read.
  Future<String> decryptStored(String stored) =>
      isEncrypted(stored) ? decrypt(stored) : Future.value(stored);

  Future<String> _call(String method, String text) async {
    final override = _debugOverride;
    if (override != null) return override(method, {'text': text});
    final result = await quaxMethodChannel.invokeMethod<String>(method, {
      'text': text,
    });
    if (result == null) {
      throw StateError('Session $method returned no value');
    }
    return result;
  }
}
