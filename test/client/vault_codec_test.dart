import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/client/vault_codec.dart';

void main() {
  const passphrase = 'correct horse battery';
  VaultCodec codec() => VaultCodec(iterations: 10000, random: Random(7));

  Matcher vaultFailure(VaultFailure failure) => throwsA(
      isA<VaultException>().having((error) => error.failure, 'failure', failure));

  Map<String, dynamic> payload() => {
        'format': 'quax.accounts',
        'accounts': [
          {'screen_name': 'alice', 'auth_header': 'auth_token=SECRET;ct0=csrf'}
        ]
      };

  test('Should round-trip a payload without leaving its secrets in the file', () async {
    final source = payload();
    final envelope = await codec().encrypt(passphrase: passphrase, kind: 'accounts', payload: source);

    expect(envelope, isNot(contains('SECRET')),
        reason: 'The whole point of the vault is that a copied file does not carry a live session token');
    expect(envelope, isNot(contains('alice')),
        reason: 'Even the handle is encrypted; a backup lying in cloud storage should not reveal who uses the app');
    expect(envelope, isNot(contains('auth_token')),
        reason: 'Searching the envelope for a cookie name must not confirm it is inside in plaintext');

    final decoded = await codec().decrypt(
        passphrase: passphrase, kind: 'accounts', envelope: envelope);
    expect(decoded, source,
        reason: 'Restoring must give the exporter exactly the payload it wrote');
  });

  test('Should reject a wrong passphrase instead of returning garbage', () async {
    final envelope = await codec().encrypt(passphrase: passphrase, kind: 'accounts', payload: payload());

    await expectLater(
        codec().decrypt(passphrase: 'wrong horse battery', kind: 'accounts', envelope: envelope),
        vaultFailure(VaultFailure.wrongPassphrase),
        reason: 'The GCM tag is the only way to tell a typo from a corrupt file; silently returning '
            'bad JSON would be worse than an error');
  });

  test('Should reject a tampered ciphertext', () async {
    final envelope = await codec().encrypt(passphrase: passphrase, kind: 'accounts', payload: payload());
    final map = jsonDecode(envelope) as Map<String, dynamic>;
    final bytes = base64Decode(map['payload'] as String);
    bytes[0] ^= 1;
    map['payload'] = base64Encode(bytes);

    await expectLater(
        codec().decrypt(
            passphrase: passphrase, kind: 'accounts', envelope: jsonEncode(map)),
        vaultFailure(VaultFailure.wrongPassphrase),
        reason: 'A flipped ciphertext byte must fail the authentication tag');
  });

  test('Should reject a vault from a newer format', () async {
    final envelope = await codec().encrypt(passphrase: passphrase, kind: 'accounts', payload: payload());
    final map = jsonDecode(envelope) as Map<String, dynamic>;
    map['version'] = 99;

    await expectLater(
        codec().decrypt(passphrase: passphrase, kind: 'accounts', envelope: jsonEncode(map)),
        vaultFailure(VaultFailure.unsupportedVersion),
        reason: 'Opening a newer file as if it were v1 could misinterpret fields instead of asking '
            'the reader to update the app');
  });

  test('Should reject a weakened or malformed KDF header', () async {
    final envelope = await codec().encrypt(passphrase: passphrase, kind: 'accounts', payload: payload());
    final map = jsonDecode(envelope) as Map<String, dynamic>;
    (map['kdf'] as Map<String, dynamic>)['iterations'] = 5000;

    await expectLater(
        codec().decrypt(passphrase: passphrase, kind: 'accounts', envelope: jsonEncode(map)),
        vaultFailure(VaultFailure.corrupt),
        reason: 'A file that asks for 5k PBKDF2 rounds is not one this app wrote; accepting it '
            'would let an attacker cheaply brute-force a re-encrypted payload');
  });

  test('Should reject malformed JSON and the wrong kind', () async {
    await expectLater(
        codec().decrypt(passphrase: passphrase, kind: 'accounts', envelope: '{not json'),
        vaultFailure(VaultFailure.corrupt));

    final envelope = await codec().encrypt(passphrase: passphrase, kind: 'accounts', payload: payload());
    await expectLater(
        codec().decrypt(passphrase: passphrase, kind: 'likes', envelope: envelope),
        vaultFailure(VaultFailure.corrupt),
        reason: 'An account vault must not be imported as a likes vault; the kind is authenticated');
  });

  test('Should refuse a weak passphrase and an oversized envelope', () async {
    await expectLater(
        codec().encrypt(passphrase: 'short', kind: 'accounts', payload: payload()),
        vaultFailure(VaultFailure.weakPassphrase));

    final tiny = VaultCodec(iterations: 10000, maxEnvelopeLength: 10);
    await expectLater(
        tiny.encrypt(passphrase: passphrase, kind: 'accounts', payload: payload()),
        vaultFailure(VaultFailure.tooLarge),
        reason: 'The UI can tell the reader the file is too large instead of trying to parse a '
            'multi-megabyte string a malicious picker returned');
  });

  test('Should use a fresh salt and nonce for every encryption', () async {
    final first = await VaultCodec(iterations: 10000)
        .encrypt(passphrase: passphrase, kind: 'accounts', payload: payload());
    final second = await VaultCodec(iterations: 10000)
        .encrypt(passphrase: passphrase, kind: 'accounts', payload: payload());

    expect(first, isNot(second),
        reason: 'Reusing a nonce with the same key would break GCM; each file must get its own salt '
            'and nonce');
  });
}
