import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:quax/client/accounts.dart';
import 'package:quax/client/vault_codec.dart';
import 'package:quax/constants.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/utils/atomic_file.dart';
import 'package:uuid/uuid.dart';

const String accountFolderName = 'QuaXAccount';
const String accountVaultFileName = 'accounts.quaxvault';
const String accountVaultBackupFileName = 'accounts.quaxvault.bak';
const String _vaultKind = 'accounts';
const String _payloadFormat = 'quax.accounts';
const int _payloadVersion = 1;
const int _maxAccounts = 50;

class AccountVaultNotFound implements Exception {
  const AccountVaultNotFound();
}

class AccountVaultWriteResult {
  final int accounts;
  final String path;

  const AccountVaultWriteResult(this.accounts, this.path);
}

class AccountVaultReadResult {
  final List<Account> accounts;
  final int invalid;
  final String path;

  const AccountVaultReadResult(this.accounts, this.invalid, this.path);

  Account? get preferredActive {
    for (final account in accounts) {
      if (account.isActive) return account;
    }
    return accounts.isEmpty ? null : accounts.first;
  }
}

/// The folder beside `QuaXLibrary` that holds the encrypted account backup.
/// The library path is the user-picked parent plus `QuaXLibrary`; the account
/// folder is a sibling, so changing the library does not put the vault inside
/// the media tree.
String? accountFolderPathFor(String libraryPath) {
  if (libraryPath.isEmpty) return null;
  final parent = p.dirname(libraryPath);
  if (parent.isEmpty || parent == '.') return null;
  return p.join(parent, accountFolderName);
}

String? accountVaultPathFor(String libraryPath) {
  final folder = accountFolderPathFor(libraryPath);
  return folder == null ? null : p.join(folder, accountVaultFileName);
}

/// Creates `QuaXAccount` and its `.nomedia` marker. Returns the folder path.
Future<String?> ensureAccountFolder(String libraryPath) async {
  final path = accountFolderPathFor(libraryPath);
  if (path == null) return null;

  final folder = Directory(path);
  await folder.create(recursive: true);
  final nomedia = File(p.join(path, '.nomedia'));
  if (!await nomedia.exists()) {
    await nomedia.create();
  }
  return path;
}

/// Reads and writes the encrypted account vault. The vault holds the session
/// material (cookies + csrf token) needed to restore an account without the
/// login webview; it is never written as plaintext.
class AccountVault {
  AccountVault({VaultCodec? codec}) : _codec = codec ?? const VaultCodec();

  final VaultCodec _codec;

  Future<AccountVaultWriteResult> write({
    required String libraryPath,
    required String passphrase,
  }) async {
    final accounts = await getAccounts();
    if (accounts.isEmpty) {
      throw StateError('There is no account to back up');
    }

    final folder = await ensureAccountFolder(libraryPath);
    if (folder == null) {
      throw const VaultException(VaultFailure.corrupt);
    }

    final payload = <String, dynamic>{
      'format': _payloadFormat,
      'version': _payloadVersion,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'accounts': accounts.map(_accountToJson).toList(),
    };
    final envelope = await _codec.encrypt(
      passphrase: passphrase,
      kind: _vaultKind,
      payload: payload,
    );

    final file = File(p.join(folder, accountVaultFileName));
    final backup = File(p.join(folder, accountVaultBackupFileName));
    if (await file.exists()) {
      try {
        await file.copy(backup.path);
      } catch (_) {
        // A backup that cannot be refreshed does not block the new vault.
      }
    }
    await writeAtomically(file, envelope);
    return AccountVaultWriteResult(accounts.length, file.path);
  }

  Future<AccountVaultReadResult> read({
    required String libraryPath,
    required String passphrase,
  }) async {
    final folder = accountFolderPathFor(libraryPath);
    if (folder == null) throw const AccountVaultNotFound();

    final primary = File(p.join(folder, accountVaultFileName));
    final backup = File(p.join(folder, accountVaultBackupFileName));
    if (!await primary.exists() && !await backup.exists()) {
      throw const AccountVaultNotFound();
    }

    if (await primary.exists()) {
      try {
        return await _readFile(primary, passphrase);
      } on VaultException {
        // The primary may have been replaced by a foreign or half-written file.
        // Try the previous copy before surfacing the error; a wrong passphrase
        // only costs a second KDF run.
        if (!await backup.exists()) rethrow;
      }
    }

    if (await backup.exists()) {
      return _readFile(backup, passphrase);
    }
    throw const AccountVaultNotFound();
  }

  Future<void> delete(String libraryPath) async {
    final folder = accountFolderPathFor(libraryPath);
    if (folder == null) return;
    for (final name in [accountVaultFileName, accountVaultBackupFileName]) {
      final file = File(p.join(folder, name));
      if (await file.exists()) await file.delete();
    }
  }

  Future<AccountVaultReadResult> _readFile(File file, String passphrase) async {
    if (await file.length() > _codec.maxEnvelopeLength) {
      throw const VaultException(VaultFailure.tooLarge);
    }
    final envelope = await file.readAsString();
    final payload = await _codec.decrypt(
      passphrase: passphrase,
      kind: _vaultKind,
      envelope: envelope,
    );
    return _parsePayload(payload, file.path);
  }

  AccountVaultReadResult _parsePayload(Map<String, dynamic> payload, String path) {
    if (payload['format'] != _payloadFormat || payload['version'] != _payloadVersion) {
      throw const VaultException(VaultFailure.unsupportedVersion);
    }
    final entries = payload['accounts'];
    if (entries is! List || entries.isEmpty || entries.length > _maxAccounts) {
      throw const VaultException(VaultFailure.corrupt);
    }

    final accounts = <Account>[];
    var invalid = 0;
    for (final entry in entries) {
      try {
        final account = _accountFromJson(entry);
        if (account == null) {
          invalid++;
        } else {
          accounts.add(account);
        }
      } catch (_) {
        invalid++;
      }
    }

    if (accounts.isEmpty) throw const VaultException(VaultFailure.corrupt);
    return AccountVaultReadResult(accounts, invalid, path);
  }

  Map<String, dynamic> _accountToJson(Account account) {
    return {
      'local_id': account.localId,
      'screen_name': account.screenName,
      'user_id': account.userId,
      'auth_header': account.authHeader is String
          ? account.authHeader
          : jsonEncode(account.authHeader),
      'is_active': account.isActive,
    };
  }

  Account? _accountFromJson(Object? entry) {
    if (entry is! Map) return null;
    final screenName = _handle(entry['screen_name']);
    if (screenName == null) return null;

    final header = _authHeader(entry['auth_header']);
    if (header == null) return null;
    final ct0 = header['x-csrf-token'] as String;

    final rawUserId = entry['user_id'];
    final userId = rawUserId is String && RegExp(r'^\d+$').hasMatch(rawUserId) ? rawUserId : null;
    final rawLocalId = entry['local_id'];
    final localId = rawLocalId is String && rawLocalId.isNotEmpty
        ? rawLocalId
        : const Uuid().v4();

    return Account(
      id: ct0,
      authHeader: jsonEncode(header),
      screenName: screenName,
      userId: userId,
      localId: localId,
      isActive: entry['is_active'] == true,
    );
  }

  String? _handle(Object? value) {
    if (value is! String) return null;
    final handle = value.trim().replaceFirst(RegExp(r'^@'), '');
    if (!RegExp(r'^[A-Za-z0-9_]{1,15}$').hasMatch(handle)) return null;
    return handle;
  }

  /// Rebuilds the session header from the stored cookies. The bearer is taken
  /// from the running app, not from the backup, so an old app version cannot
  /// pin a stale bearer; the csrf token is always the one in `ct0`.
  Map<String, dynamic>? _authHeader(Object? value) {
    dynamic raw = value;
    if (raw is String) {
      try {
        raw = jsonDecode(raw);
      } on FormatException {
        return null;
      }
    }
    if (raw is! Map) return null;

    final cookieValue = _valueIgnoringCase(raw, 'Cookie');
    if (cookieValue is! String || cookieValue.isEmpty) return null;

    final cookies = <String, String>{};
    for (final part in cookieValue.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      final name = part.substring(0, separator).trim();
      final value = part.substring(separator + 1).trim();
      if (name.isEmpty) continue;
      cookies[name] = value;
    }

    final authToken = cookies['auth_token'];
    final ct0 = cookies['ct0'];
    if (authToken == null || authToken.isEmpty || ct0 == null || ct0.isEmpty) {
      return null;
    }

    return {
      'Cookie': cookies.entries.map((e) => '${e.key}=${e.value}').join(';'),
      'authorization': bearerToken,
      'x-csrf-token': ct0,
    };
  }

  Object? _valueIgnoringCase(Map map, String key) {
    for (final entry in map.entries) {
      if (entry.key is String && (entry.key as String).toLowerCase() == key.toLowerCase()) {
        return entry.value;
      }
    }
    return null;
  }
}
