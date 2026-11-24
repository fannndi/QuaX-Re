import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:quax/client/accounts.dart';
import 'package:quax/client/vault_codec.dart';
import 'package:quax/client/vault_paths.dart';
import 'package:quax/constants.dart';
import 'package:quax/database/entities.dart';
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
class AccountVault implements VaultPassphraseSource {
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
    if (accounts.length > _maxAccounts) {
      throw StateError(
        'An account vault supports at most $_maxAccounts accounts',
      );
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
    await _replaceEnvelope(
      folder: folder,
      passphrase: passphrase,
      envelope: envelope,
      removeBackups: false,
    );
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

  /// Re-authenticates [sourcePath] and writes the current, merged database as a
  /// complete vault. Copying the source bytes after an import could omit local
  /// accounts that were not present in that older file.
  Future<void> adoptFile({
    required String sourcePath,
    required String vaultRoot,
    required String passphrase,
  }) async {
    await readFile(filePath: sourcePath, passphrase: passphrase);
    await write(vaultRoot: vaultRoot, passphrase: passphrase);
  }

  /// Encrypts the validated current payload without replacing either file.
  /// Callers rotating account and likes vaults together stage both results
  /// before committing any primary.
  @override
  Future<String> preparePassphraseChange({
    required String vaultRoot,
    required String oldPassphrase,
    required String newPassphrase,
  }) async {
    final folder = accountFolderPathFor(vaultRoot);
    if (folder == null) throw const AccountVaultNotFound();
    final (payload, _) = await _decryptFromFolder(folder, oldPassphrase);
    return _codec.encrypt(
      passphrase: newPassphrase,
      kind: _vaultKind,
      payload: payload,
    );
  }

  @override
  Future<bool> canBackupPrimary({
    required String vaultRoot,
    required String passphrase,
  }) async {
    final folder = accountFolderPathFor(vaultRoot);
    if (folder == null) return false;
    return _canBackup(File(p.join(folder, accountVaultFileName)), passphrase);
  }

  @override
  VaultReplacement replacementFor({
    required String vaultRoot,
    required String envelope,
    required String passphrase,
  }) {
    final folder = accountFolderPathFor(vaultRoot)!;
    final primary = File(p.join(folder, accountVaultFileName));
    return VaultReplacement(
      primary: primary,
      backup: File(p.join(folder, accountVaultBackupFileName)),
      envelope: envelope,
      validatePrimary: () => _canBackup(primary, passphrase),
    );
  }

  /// Re-encrypts the existing payload with [newPassphrase]. The old `.bak` is
  /// removed after success so the old passphrase does not keep opening a copy.
  Future<void> changePassphrase({
    required String vaultRoot,
    required String oldPassphrase,
    required String newPassphrase,
  }) async {
    final envelope = await preparePassphraseChange(
      vaultRoot: vaultRoot,
      oldPassphrase: oldPassphrase,
      newPassphrase: newPassphrase,
    );
    final folder = accountFolderPathFor(vaultRoot)!;
    await _replaceEnvelope(
      folder: folder,
      passphrase: oldPassphrase,
      envelope: envelope,
    );
  }

  Future<void> _replaceEnvelope({
    required String folder,
    required String passphrase,
    required String envelope,
    bool removeBackups = true,
  }) => replaceVaultFiles([
    VaultReplacement(
      primary: File(p.join(folder, accountVaultFileName)),
      backup: File(p.join(folder, accountVaultBackupFileName)),
      envelope: envelope,
      validatePrimary: () =>
          _canBackup(File(p.join(folder, accountVaultFileName)), passphrase),
    ),
  ], removeBackups: removeBackups);

  Future<bool> _canBackup(File file, String passphrase) async {
    try {
      _parsePayload(await _decryptFile(file, passphrase), file.path);
      return true;
    } on VaultException {
      return false;
    }
  }

  Future<bool> exists(String vaultRoot) async {
    final folder = accountFolderPathFor(vaultRoot);
    if (folder == null) return false;
    return await File(p.join(folder, accountVaultFileName)).exists() ||
        await File(p.join(folder, accountVaultBackupFileName)).exists();
  }

  Future<DateTime?> lastSaved(String vaultRoot) async {
    final folder = accountFolderPathFor(vaultRoot);
    if (folder == null) return null;
    final dates = <DateTime>[];
    for (final name in [accountVaultFileName, accountVaultBackupFileName]) {
      final file = File(p.join(folder, name));
      if (await file.exists()) dates.add((await file.stat()).modified);
    }
    if (dates.isEmpty) return null;
    dates.sort();
    return dates.last;
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
    String folder,
    String passphrase,
  ) async {
    final primary = File(p.join(folder, accountVaultFileName));
    final backup = File(p.join(folder, accountVaultBackupFileName));
    if (!await primary.exists() && !await backup.exists()) {
      throw const AccountVaultNotFound();
    }

    if (await primary.exists()) {
      try {
        final payload = await _decryptFile(primary, passphrase);
        _parsePayload(payload, primary.path);
        return (payload, primary.path);
      } on VaultException catch (error) {
        // The primary may have been replaced by a foreign or half-written file,
        // or one of its bytes may have rotted: a GCM tag failure is
        // indistinguishable from a wrong passphrase, so try the backup for
        // that too (one extra KDF run). A vault from a newer format is not
        // recoverable from the backup: falling back would silently restore an
        // older account list and report success.
        if (error.failure != VaultFailure.corrupt &&
            error.failure != VaultFailure.tooLarge &&
            error.failure != VaultFailure.wrongPassphrase) {
          rethrow;
        }
        if (!await backup.exists()) rethrow;
      }
    }

    if (await backup.exists()) {
      final payload = await _decryptFile(backup, passphrase);
      _parsePayload(payload, backup.path);
      return (payload, backup.path);
    }
    throw const AccountVaultNotFound();
  }

  Future<Map<String, dynamic>> _decryptFile(
    File file,
    String passphrase,
  ) async {
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

  AccountVaultReadResult _parsePayload(
    Map<String, dynamic> payload,
    String path,
  ) {
    if (payload['format'] != _payloadFormat) {
      throw const VaultException(VaultFailure.corrupt);
    }
    final version = payload['version'];
    if (version is! int || version < 1) {
      throw const VaultException(VaultFailure.corrupt);
    }
    if (version > _payloadVersion) {
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
    final userId = rawUserId is String && RegExp(r'^\d+$').hasMatch(rawUserId)
        ? rawUserId
        : null;
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
      if (entry.key is String &&
          (entry.key as String).toLowerCase() == key.toLowerCase()) {
        return entry.value;
      }
    }
    return null;
  }
}

/// Imports a nonempty restore, marks the backup dirty before touching the
/// vault, then writes the complete merged database. An all-kept import still
/// counts because it can change the preferred account. The dirty bit is
/// cleared only after the fresh write/adoption succeeds.
Future<AccountImportResult> restoreAccountsAndRewriteVault({
  required AccountVault accountVault,
  required List<Account> accounts,
  required bool replaceExisting,
  required String vaultRoot,
  required String passphrase,
  String? sourcePath,
  required Future<void> Function(bool dirty) saveDirty,
}) async {
  final imported = await importAccounts(
    accounts,
    replaceExisting: replaceExisting,
  );
  if (imported.total == 0) return imported;

  await saveDirty(true);
  if (sourcePath == null) {
    await accountVault.write(vaultRoot: vaultRoot, passphrase: passphrase);
  } else {
    await accountVault.adoptFile(
      sourcePath: sourcePath,
      vaultRoot: vaultRoot,
      passphrase: passphrase,
    );
  }
  await saveDirty(false);
  return imported;
}
