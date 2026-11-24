import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/session_crypto.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    SessionCrypto.debugOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('browser_resolver'),
          null,
        );
  });

  test('Should round-trip through the agreed browser_resolver methods', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('browser_resolver'), (
          call,
        ) async {
          calls.add(call);
          if (call.method == 'encryptSession') {
            return '${SessionCrypto.encryptedPrefix}${base64Url.encode(utf8.encode(call.arguments['text'] as String))}';
          }
          if (call.method == 'decryptSession') {
            return utf8.decode(
              base64Url.decode(call.arguments['text'] as String),
            );
          }
          throw MissingPluginException();
        });

    const crypto = SessionCrypto();
    final stored = await crypto.encrypt('auth_token=SECRET;ct0=csrf');

    expect(calls.map((call) => call.method), [
      'encryptSession',
    ], reason: 'Persistence encrypts through the agreed native method');
    expect(calls.single.arguments, {
      'text': 'auth_token=SECRET;ct0=csrf',
    }, reason: 'The native encrypt call receives plaintext under the text key');
    expect(
      SessionCrypto.isEncrypted(stored),
      isTrue,
      reason:
          'Dart marks the native ciphertext with its storage version prefix',
    );
    expect(
      stored,
      isNot(contains('SECRET')),
      reason: 'The stored value must not carry the live auth token',
    );
    expect(
      await crypto.decrypt(stored),
      'auth_token=SECRET;ct0=csrf',
      reason: 'Decrypting the stored value returns the original header',
    );
    expect(calls.map((call) => call.method), [
      'encryptSession',
      'decryptSession',
    ], reason: 'Reads use the agreed native decrypt method after encryption');
    expect(calls.last.arguments, {
      'text': stored.substring(SessionCrypto.encryptedPrefix.length),
    }, reason: 'The Dart-only prefix is stripped before native decryption');
  });

  test('Should read legacy plaintext without invoking native code', () async {
    const crypto = SessionCrypto();
    expect(
      await crypto.decryptStored('{"Cookie":"auth_token=legacy"}'),
      '{"Cookie":"auth_token=legacy"}',
      reason:
          'Legacy plaintext is returned unchanged without requiring Keystore',
    );
  });

  test('Should provide a debug override for isolated tests', () async {
    SessionCrypto.debugOverride = (method, arguments) async {
      expect(
        method,
        'encryptSession',
        reason: 'The debug override observes the same method contract as the channel',
      );
      return '${SessionCrypto.encryptedPrefix}test-ciphertext';
    };

    expect(
      await const SessionCrypto().encrypt('plaintext'),
      '${SessionCrypto.encryptedPrefix}test-ciphertext',
      reason: 'The override result is stored with the same version marker',
    );
  });
}
