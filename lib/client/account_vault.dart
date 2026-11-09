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
}

/// The folder that holds the encrypted account backup.
///
/// [vaultRoot] is the shared-storage folder chosen for backups, not the media
/// library: a hidden library lives under `Android/data`, which is erased on
/// uninstall, while the vault exists to survive it.
String? accountFolderPathFor(String vaultRoot) {
  if (vaultRoot.isEmpty) return null;
  return p.join(vaultRoot, accountFolderName);
}

String? accountVaultPathFor(String vaultRoot) {
  final folder = accountFolderPathFor(vaultRoot);
  return folder == null ? null : p.join(folder, accountVaultFileName);
}

/// Creates `QuaXAccount` and its `.nomedia` marker. Returns the folder path.
Future<String?> ensureAccountFolder(String vaultRoot) async {
  final path = accountFolderPathFor(vaultRoot);
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
    required String vaultRoot,
    required String passphrase,
  }) async {
    final accounts = await getAccounts();
    if (accounts.isEmpty) {
      throw StateError('There is no account to back up');
    }

    final folder = await ensureAccountFolder(vaultRoot);
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
    required String vaultRoot,
    required String passphrase,
  }) async {
    final folder = accountFolderPathFor(vaultRoot);
    if (folder == null) throw const AccountVaultNotFound();

    final (payload, path) = await _decryptFromFolder(folder, passphrase);
    return _parsePayload(payload, path);
  }

  /// Reads one vault file the reader picked from another location. It is not
  /// copied into QuaXAccount until [adoptFile] is called.
  Future<AccountVaultReadResult> readFile({
    required String filePath,
    required String passphrase,
  }) async {
    final payload = await _decryptFile(File(filePath), passphrase);
    return _parsePayload(payload, filePath);
  }

  /// Copies an already-read vault file into the fixed QuaXAccount path, so the
  /// next onboarding finds it automatically.
  Future<void> adoptFile({required String sourcePath, required String vaultRoot}) async {
    final source = File(sourcePath);
    if (!await source.exists()) throw const AccountVaultNotFound();
    if (await source.length() > _codec.maxEnvelopeLength) {
      throw const VaultException(VaultFailure.tooLarge);
    }

    final envelope = await source.readAsString();
    _checkEnvelopeShape(envelope);

    final folder = await ensureAccountFolder(vaultRoot);
    if (folder == null) throw const VaultException(VaultFailure.corrupt);
    final target = File(p.join(folder, accountVaultFileName));
    final backup = File(p.join(folder, accountVaultBackupFileName));
    if (await target.exists()) {
      try {
        await target.copy(backup.path);
      } catch (_) {
        // Adopting the imported file still succeeds without a rollback copy.
      }
    }
    await writeAtomically(target, envelope);
  }

  /// Re-encrypts the existing payload with [newPassphrase]. The old `.bak` is
  /// removed after success so the old passphrase does not keep opening a copy.
  Future<void> changePassphrase({
    required String vaultRoot,
    required String oldPassphrase,
    required String newPassphrase,
  }) async {
    final folder = accountFolderPathFor(vaultRoot);
    if (folder == null) throw const AccountVaultNotFound();

    final (payload, _) = await _decryptFromFolder(folder, oldPassphrase);
    final envelope = await _codec.encrypt(
      passphrase: newPassphrase,
      kind: _vaultKind,
      payload: payload,
    );

    final target = File(p.join(folder, accountVaultFileName));
    await writeAtomically(target, envelope);

    final backup = File(p.join(folder, accountVaultBackupFileName));
    if (await backup.exists()) await backup.delete();
  }

  Future<bool> exists(String vaultRoot) async {
    final path = accountVaultPathFor(vaultRoot);
    return path != null && await File(path).exists();
  }

  Future<DateTime?> lastSaved(String vaultRoot) async {
    final path = accountVaultPathFor(vaultRoot);
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    return (await file.stat()).modified;
  }

  Future<void> delete(String vaultRoot) async {
    final folder = accountFolderPathFor(vaultRoot);
    if (folder == null) return;
    for (final name in [accountVaultFileName, accountVaultBackupFileName]) {
      final file = File(p.join(folder, name));
      if (await file.exists()) await file.delete();
    }
  }

  Future<(Map<String, dynamic>, String)> _decryptFromFolder(
      String folder, String passphrase) async {
    final primary = File(p.join(folder, accountVaultFileName));
    final backup = File(p.join(folder, accountVaultBackupFileName));
    if (!await primary.exists() && !await backup.exists()) {
      throw const AccountVaultNotFound();
    }

    if (await primary.exists()) {
      try {
        return (await _decryptFile(primary, passphrase), primary.path);
      } on VaultException catch (error) {
        // The primary may have been replaced by a foreign or half-written file.
        // Try the previous copy before surfacing the error; a wrong passphrase
        // only costs a second KDF run. A vault from a newer format is not
        // recoverable from the backup: falling back would silently restore an
        // older account list and report success.
        if (error.failure != VaultFailure.corrupt && error.failure != VaultFailure.tooLarge) {
          rethrow;
        }
        if (!await backup.exists()) rethrow;
      }
    }

    if (await backup.exists()) {
      return (await _decryptFile(backup, passphrase), backup.path);
    }
    throw const AccountVaultNotFound();
  }

  Future<Map<String, dynamic>> _decryptFile(File file, String passphrase) async {
    if (await file.length() > _codec.maxEnvelopeLength) {
      throw const VaultException(VaultFailure.tooLarge);
    }
    final envelope = await file.readAsString();
    return _codec.decrypt(
      passphrase: passphrase,
      kind: _vaultKind,
      envelope: envelope,
    );
  }

  void _checkEnvelopeShape(String envelope) {
    try {
      final parsed = jsonDecode(envelope);
      if (parsed is! Map ||
          parsed['format'] != VaultCodec.format ||
          parsed['kind'] != _vaultKind) {
        throw const VaultException(VaultFailure.corrupt);
      }
    } on FormatException {
      throw const VaultException(VaultFailure.corrupt);
    }
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
