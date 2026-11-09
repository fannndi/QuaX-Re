import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:quax/client/account_vault.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/client/vault_codec.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/utils/atomic_file.dart';
import 'package:sqflite/sqflite.dart';

const String likesVaultFileName = 'likes.quaxvault';
const String likesVaultBackupFileName = 'likes.quaxvault.bak';
const String _vaultKind = 'likes';
const String _payloadFormat = 'quax.likes';
const int _payloadVersion = 1;
const int _pageSize = 500;

/// Compressed NDJSON is encrypted as one blob; the cap keeps the base64
/// envelope and its plaintext copies from exhausting a phone's memory.
const int maxLikesCompressedBytes = 16 * 1024 * 1024;

/// A gzip stream can expand far beyond the encrypted file's size. This bound
/// is generous for real likes (JSON rarely compresses better than ~10x) while
/// keeping a hand-crafted vault from filling the disk.
const int maxLikesPlaintextBytes = maxLikesCompressedBytes * 16;

String? likesVaultPathFor(String libraryPath) {
  final folder = accountFolderPathFor(libraryPath);
  return folder == null ? null : p.join(folder, likesVaultFileName);
}

class LikesVaultNotFound implements Exception {
  const LikesVaultNotFound();
}

class LikesVaultNoAccounts implements Exception {
  const LikesVaultNoAccounts();
}

class LikesVaultTooLarge implements Exception {
  const LikesVaultTooLarge();
}

class LikesVaultWriteResult {
  final int likes;
  final String path;

  const LikesVaultWriteResult(this.likes, this.path);
}

class LikesVaultReadResult {
  final int likes;
  final int accounts;
  final String path;

  const LikesVaultReadResult(this.likes, this.accounts, this.path);
}

class LikesVaultImportResult {
  final int restored;
  final int skipped;
  final int missingAccounts;

  const LikesVaultImportResult({
    required this.restored,
    required this.skipped,
    required this.missingAccounts,
  });
}

class _LikeRow {
  final String owner;
  final String id;
  final String? user;
  final String content;
  final String at;

  const _LikeRow(this.owner, this.id, this.user, this.content, this.at);
}

/// The local-likes companion to [AccountVault].
///
/// The plaintext is a four-byte big-endian metadata length, the metadata JSON
/// (account mapping and count), then a gzipped NDJSON stream of
/// `account_like` rows joined with their tweet body. The metadata is inside
/// the encryption, so the file does not reveal who liked what.
class LikesVault {
  LikesVault({VaultCodec? codec, Future<Directory> Function()? tempDirectory})
      : _codec = codec ?? const VaultCodec(maxEnvelopeLength: 48 * 1024 * 1024),
        _tempDirectory = tempDirectory ?? getTemporaryDirectory;

  final VaultCodec _codec;
  final Future<Directory> Function() _tempDirectory;

  Future<LikesVaultWriteResult> write({
    required String libraryPath,
    required String passphrase,
  }) async {
    final folder = await ensureAccountFolder(libraryPath);
    if (folder == null) throw const VaultException(VaultFailure.corrupt);

    final accounts = await getAccounts();
    if (accounts.isEmpty) throw const LikesVaultNoAccounts();

    final tempDir = await _tempDirectory();
    final gzFile = File(p.join(tempDir.path,
        'quax-likes-${DateTime.now().microsecondsSinceEpoch}.gz'));
    var count = 0;
    IOSink? sink;
    ByteConversionSink? gzipSink;

    try {
      sink = gzFile.openWrite();
      gzipSink = gzip.encoder.startChunkedConversion(sink);
      count = await Repository.read((db) async {
        var offset = 0;
        var total = 0;
        while (true) {
          final rows = await db.rawQuery('''
            SELECT al.$columnAccountLocalId AS owner,
                   al.$columnTweetId AS tweet,
                   al.$columnLikedAt AS liked_at,
                   lt.user_id AS user,
                   lt.content AS content
            FROM $tableAccountLike al
            JOIN $tableLikedTweet lt ON lt.id = al.$columnTweetId
            ORDER BY al.$columnLikedAt DESC
            LIMIT ? OFFSET ?
          ''', [_pageSize, offset]);
          for (final row in rows) {
            gzipSink!.add(utf8.encode('${jsonEncode({
              'account': row['owner'],
              'id': row['tweet'],
              'user': row['user'],
              'at': row['liked_at'],
              'content': row['content'],
            })}\n'));
            total++;
          }
          if (rows.length < _pageSize) break;
          offset += rows.length;
        }
        return total;
      });
      gzipSink.close();
      await sink.close();
      gzipSink = null;
      sink = null;

      if (count == 0) throw StateError('There are no local likes to back up');
      final compressed = await gzFile.readAsBytes();
      if (compressed.length > maxLikesCompressedBytes) {
        throw const LikesVaultTooLarge();
      }

      final container = _container(_metadata(accounts, count), compressed);
      final envelope = await _codec.encryptBytes(
        passphrase: passphrase,
        kind: _vaultKind,
        bytes: container,
      );

      final file = File(p.join(folder, likesVaultFileName));
      final backup = File(p.join(folder, likesVaultBackupFileName));
      if (await file.exists()) {
        try {
          await file.copy(backup.path);
        } catch (_) {
          // A backup that cannot be refreshed does not block the new file.
        }
      }
      await writeAtomically(file, envelope);
      return LikesVaultWriteResult(count, file.path);
    } finally {
      try {
        gzipSink?.close();
      } catch (_) {}
      try {
        await sink?.close();
      } catch (_) {}
      if (await gzFile.exists()) await gzFile.delete();
    }
  }

  Future<LikesVaultReadResult> read({
    required String libraryPath,
    required String passphrase,
  }) async {
    final folder = accountFolderPathFor(libraryPath);
    if (folder == null) throw const LikesVaultNotFound();
    final decrypted = await _decryptFromFolder(folder, passphrase);
    return LikesVaultReadResult(
        (decrypted.meta['like_count'] as int?) ?? 0,
        (decrypted.meta['accounts'] as List?)?.length ?? 0,
        decrypted.path);
  }

  /// Imports the likes from [filePath], then copies the encrypted file into
  /// QuaXAccount so a later restore finds it automatically.
  Future<LikesVaultImportResult> importFile({
    required String filePath,
    required String libraryPath,
    required String passphrase,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) throw const LikesVaultNotFound();
    if (await file.length() > _codec.maxEnvelopeLength) {
      throw const LikesVaultTooLarge();
    }
    final envelope = await file.readAsString();
    final bytes = await _codec.decryptBytes(
        passphrase: passphrase, kind: _vaultKind, envelope: envelope);
    final decrypted = _parseContainer(bytes, filePath);
    final result = await _importDecrypted(decrypted);
    await _adoptEnvelope(libraryPath, envelope);
    return result;
  }

  Future<LikesVaultImportResult> import({
    required String libraryPath,
    required String passphrase,
  }) async {
    final folder = accountFolderPathFor(libraryPath);
    if (folder == null) throw const LikesVaultNotFound();
    final decrypted = await _decryptFromFolder(folder, passphrase);
    return _importDecrypted(decrypted);
  }

  Future<void> adoptFile({required String sourcePath, required String libraryPath}) async {
    final source = File(sourcePath);
    if (!await source.exists()) throw const LikesVaultNotFound();
    if (await source.length() > _codec.maxEnvelopeLength) {
      throw const LikesVaultTooLarge();
    }
    final envelope = await source.readAsString();
    _checkEnvelopeShape(envelope);
    await _adoptEnvelope(libraryPath, envelope);
  }

  Future<void> changePassphrase({
    required String libraryPath,
    required String oldPassphrase,
    required String newPassphrase,
  }) async {
    final folder = accountFolderPathFor(libraryPath);
    if (folder == null) throw const LikesVaultNotFound();
    final decrypted = await _decryptFromFolder(folder, oldPassphrase);
    final envelope = await _codec.encryptBytes(
      passphrase: newPassphrase,
      kind: _vaultKind,
      bytes: _container(decrypted.meta, decrypted.compressed),
    );

    final target = File(p.join(folder, likesVaultFileName));
    await writeAtomically(target, envelope);
    final backup = File(p.join(folder, likesVaultBackupFileName));
    if (await backup.exists()) await backup.delete();
  }

  Future<bool> exists(String libraryPath) async {
    final folder = accountFolderPathFor(libraryPath);
    if (folder == null) return false;
    return File(p.join(folder, likesVaultFileName)).exists();
  }

  Future<DateTime?> lastSaved(String libraryPath) async {
    final folder = accountFolderPathFor(libraryPath);
    if (folder == null) return null;
    final file = File(p.join(folder, likesVaultFileName));
    if (!await file.exists()) return null;
    return (await file.stat()).modified;
  }

  Future<int> count() async {
    final rows = await Repository.read(
        (db) => db.rawQuery('SELECT COUNT(*) AS c FROM $tableAccountLike'));
    return (rows.first['c'] as int?) ?? 0;
  }

  /// `count:max(liked_at)`; compared with the snapshot saved after the last
  /// backup to show "out of date" without writing a preference on every like.
  Future<String> snapshot() async {
    final rows = await Repository.read((db) => db.rawQuery(
        'SELECT COUNT(*) AS c, MAX($columnLikedAt) AS m FROM $tableAccountLike'));
    final count = (rows.first['c'] as int?) ?? 0;
    final max = rows.first['m'] as String?;
    return '$count:${max ?? ''}';
  }

  Future<void> delete(String libraryPath) async {
    final folder = accountFolderPathFor(libraryPath);
    if (folder == null) return;
    for (final name in [likesVaultFileName, likesVaultBackupFileName]) {
      final file = File(p.join(folder, name));
      if (await file.exists()) await file.delete();
    }
  }

  Map<String, dynamic> _metadata(List<Account> accounts, int count) => {
        'format': _payloadFormat,
        'version': _payloadVersion,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'like_count': count,
        'accounts': accounts
            .map((account) => {
                  'local_id': account.localId,
                  'screen_name': account.screenName,
                  'user_id': account.userId,
                })
            .toList(),
      };

  Uint8List _container(Map<String, dynamic> meta, Uint8List compressed) {
    final metaBytes = utf8.encode(jsonEncode(meta));
    final builder = BytesBuilder(copy: false);
    final length = metaBytes.length;
    builder.add([
      (length >> 24) & 0xff,
      (length >> 16) & 0xff,
      (length >> 8) & 0xff,
      length & 0xff,
    ]);
    builder.add(metaBytes);
    builder.add(compressed);
    return builder.takeBytes();
  }

  Future<({Map<String, dynamic> meta, Uint8List compressed, String path})>
      _decryptFromFolder(String folder, String passphrase) async {
    final primary = File(p.join(folder, likesVaultFileName));
    final backup = File(p.join(folder, likesVaultBackupFileName));
    if (!await primary.exists() && !await backup.exists()) {
      throw const LikesVaultNotFound();
    }

    if (await primary.exists()) {
      try {
        return await _decryptFile(primary, passphrase);
      } on VaultException catch (error) {
        // Only a damaged/oversized primary is worth retrying from the older
        // backup. A newer format must surface as unsupported instead of
        // silently restoring an older snapshot.
        if (error.failure != VaultFailure.corrupt && error.failure != VaultFailure.tooLarge) {
          rethrow;
        }
        if (!await backup.exists()) rethrow;
      }
    }
    if (await backup.exists()) return _decryptFile(backup, passphrase);
    throw const LikesVaultNotFound();
  }

  Future<({Map<String, dynamic> meta, Uint8List compressed, String path})>
      _decryptFile(File file, String passphrase) async {
    if (await file.length() > _codec.maxEnvelopeLength) {
      throw const LikesVaultTooLarge();
    }
    final envelope = await file.readAsString();
    final bytes = await _codec.decryptBytes(
        passphrase: passphrase, kind: _vaultKind, envelope: envelope);
    return _parseContainer(bytes, file.path);
  }

  ({Map<String, dynamic> meta, Uint8List compressed, String path}) _parseContainer(
      Uint8List bytes, String path) {
    if (bytes.length < 5) throw const VaultException(VaultFailure.corrupt);
    final length = (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    if (length <= 0 || length > bytes.length - 4) {
      throw const VaultException(VaultFailure.corrupt);
    }

    final Map<String, dynamic> meta;
    try {
      final decoded = jsonDecode(utf8.decode(bytes.sublist(4, 4 + length)));
      if (decoded is! Map<String, dynamic>) throw const VaultException(VaultFailure.corrupt);
      meta = decoded;
    } on FormatException {
      throw const VaultException(VaultFailure.corrupt);
    }

    if (meta['format'] != _payloadFormat) throw const VaultException(VaultFailure.corrupt);
    final version = meta['version'];
    if (version is! int || version < 1) throw const VaultException(VaultFailure.corrupt);
    if (version > _payloadVersion) {
      throw const VaultException(VaultFailure.unsupportedVersion);
    }
    return (meta: meta, compressed: bytes.sublist(4 + length), path: path);
  }

  Future<LikesVaultImportResult> _importDecrypted(
      ({Map<String, dynamic> meta, Uint8List compressed, String path}) decrypted) async {
    final mapping = await _ownerMapping(decrypted.meta);
    if (mapping.isEmpty) throw const LikesVaultNoAccounts();

    File? temp;
    var restored = 0;
    var skipped = 0;
    final rows = <_LikeRow>[];
    try {
      temp = await _decompress(decrypted.compressed);
      await for (final line in temp
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        final row = _parseLine(line, mapping);
        if (row == null) {
          skipped++;
          continue;
        }
        rows.add(row);
        if (rows.length >= _pageSize) {
          restored += await _flush(rows);
          rows.clear();
        }
      }
      restored += await _flush(rows);
    } finally {
      if (temp != null && await temp.exists()) await temp.delete();
    }

    final metaAccounts = (decrypted.meta['accounts'] as List?)?.length ?? 0;
    return LikesVaultImportResult(
      restored: restored,
      skipped: skipped,
      missingAccounts: metaAccounts > mapping.length ? metaAccounts - mapping.length : 0,
    );
  }

  _LikeRow? _parseLine(String line, Map<String, String> mapping) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return null;
      final owner = mapping[decoded['account']];
      final id = decoded['id'];
      final content = decoded['content'];
      if (owner == null || id is! String || content is! String) return null;
      final user = decoded['user'];
      final at = decoded['at'];
      return _LikeRow(
        owner,
        id,
        user is String ? user : null,
        content,
        at is String ? at : DateTime.now().toIso8601String(),
      );
    } on FormatException {
      return null;
    }
  }

  Future<Map<String, String>> _ownerMapping(Map<String, dynamic> meta) async {
    final accounts = await getAccounts();
    final byLocalId = <String, String>{for (final a in accounts) a.localId: a.localId};
    final byUserId = <String, String>{
      for (final a in accounts)
        if (a.userId != null) a.userId!: a.localId
    };
    final byHandle = <String, String>{
      for (final a in accounts)
        if (a.screenName != null) a.screenName!.toLowerCase(): a.localId
    };

    final mapping = <String, String>{};
    final entries = meta['accounts'];
    if (entries is! List) return mapping;
    for (final entry in entries) {
      if (entry is! Map) continue;
      final vaultLocalId = entry['local_id'];
      final userId = entry['user_id'];
      final handle = entry['screen_name'];
      final local = byLocalId[vaultLocalId] ??
          (userId is String ? byUserId[userId] : null) ??
          (handle is String ? byHandle[handle.toLowerCase()] : null);
      if (vaultLocalId is String && local != null) mapping[vaultLocalId] = local;
    }
    return mapping;
  }

  /// Inserts one page and returns how many `account_like` rows were actually
  /// new. `ConflictAlgorithm.ignore` made the old count include every duplicate
  /// the file carried, so a second restore claimed to have restored likes that
  /// were already there.
  Future<int> _flush(List<_LikeRow> rows) async {
    if (rows.isEmpty) return 0;
    final db = await Repository.writable();
    return db.transaction((txn) async {
      final before = await txn.rawQuery('SELECT COUNT(*) AS c FROM $tableAccountLike');
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert(
          tableLikedTweet,
          {
            'id': row.id,
            'user_id': row.user,
            'content': row.content,
            columnLikedAt: row.at,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        batch.insert(
          tableAccountLike,
          {
            columnAccountLocalId: row.owner,
            columnTweetId: row.id,
            columnLikedAt: row.at,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
      final after = await txn.rawQuery('SELECT COUNT(*) AS c FROM $tableAccountLike');
      final previous = (before.first['c'] as int?) ?? 0;
      final current = (after.first['c'] as int?) ?? 0;
      return current - previous;
    });
  }

  Future<File> _decompress(Uint8List compressed) async {
    final dir = await _tempDirectory();
    final file = File(p.join(dir.path,
        'quax-likes-import-${DateTime.now().microsecondsSinceEpoch}.jsonl'));
    final sink = file.openWrite();
    var failed = false;
    VaultException? failure;
    try {
      final bounded = _BoundedSink(sink, maxLikesPlaintextBytes);
      final decoder = gzip.decoder.startChunkedConversion(bounded);
      decoder.add(compressed);
      decoder.close();
    } catch (error) {
      failed = true;
      if (error is VaultException) failure = error;
    } finally {
      try {
        await sink.close();
      } catch (_) {
        failed = true;
      }
    }

    if (failed) {
      // A corrupt stream used to leave the decoded plaintext in the app's temp
      // directory; the caller only received the exception.
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      throw failure ?? const VaultException(VaultFailure.corrupt);
    }
    return file;
  }

  Future<void> _adoptEnvelope(String libraryPath, String envelope) async {
    _checkEnvelopeShape(envelope);
    final folder = await ensureAccountFolder(libraryPath);
    if (folder == null) throw const VaultException(VaultFailure.corrupt);
    final target = File(p.join(folder, likesVaultFileName));
    final backup = File(p.join(folder, likesVaultBackupFileName));
    if (await target.exists()) {
      try {
        await target.copy(backup.path);
      } catch (_) {}
    }
    await writeAtomically(target, envelope);
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
}

/// Stops a gzip stream once the decoded output passes [limit].
class _BoundedSink implements Sink<List<int>> {
  _BoundedSink(this._sink, this._limit);

  final IOSink _sink;
  final int _limit;
  int _written = 0;

  @override
  void add(List<int> data) {
    _written += data.length;
    if (_written > _limit) {
      throw const VaultException(VaultFailure.tooLarge);
    }
    _sink.add(data);
  }

  @override
  void close() => _sink.close();
}
