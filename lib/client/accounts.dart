import 'package:flutter/foundation.dart';
import 'package:quax/client/session_crypto.dart';
import 'package:quax/constants.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

/// Bumped whenever the preferred account actually changes, so feeds reload
/// against the new account without knowing the settings screen exists. A
/// re-selection of the current account leaves it untouched: there is nothing
/// to reload.
final ValueNotifier<int> accountsRevision = ValueNotifier<int>(0);

/// The account the app talks to, kept in memory (id + handle) so the app bar
/// and the per-account feed state (scroll positions) can use it without a
/// database read per frame. Loaded once at startup, updated on every switch.
class ActiveAccount {
  final String id;
  final String? screenName;
  // The numeric X user id, when a login page or profile request has filled it
  // in. The Likes endpoint needs it; it is not the ct0 token [id] holds.
  final String? userId;
  // The stable owner key local likes (and future per-account data) use.
  final String localId;
  final bool sessionExpired;

  const ActiveAccount({
    required this.id,
    this.screenName,
    this.userId,
    String? localId,
    this.sessionExpired = false,
  }) : localId = localId ?? id;

  String? get handle =>
      screenName == null || screenName!.isEmpty ? null : screenName;
}

final ValueNotifier<ActiveAccount?> activeAccount =
    ValueNotifier<ActiveAccount?>(null);

const _sessionCrypto = SessionCrypto();
Future<void> _accountMutationQueue = Future<void>.value();

/// One FIFO for every operation that can change account identity or the active
/// flag. The queue is process-wide: two screens (or a login and a switch) can
/// never commit in one order and publish their in-memory state in another.
Future<T> _serialized<T>(Future<T> Function() action) {
  final result = _accountMutationQueue.then((_) => action());
  _accountMutationQueue = result.then<void>(
    (_) {},
    onError: (Object _, StackTrace _) {},
  );
  return result;
}

String? _numericUserId(String? value) =>
    value != null && RegExp(r'^\d+$').hasMatch(value) ? value : null;

String? _handleKey(String? value) {
  final handle = value?.trim().replaceFirst(RegExp(r'^@'), '');
  return handle == null || handle.isEmpty ? null : handle.toLowerCase();
}

Future<List<Map<String, Object?>>> _accountRows() => Repository.read(
  (db) => db.query(
    tableAccounts,
    orderBy: 'is_active DESC, screen_name COLLATE NOCASE',
  ),
);

Future<List<Account>> _readAccounts({bool decryptHeaders = true}) async {
  final rows = await _accountRows();
  if (!decryptHeaders) return rows.map(Account.fromMap).toList();

  final accounts = <Account>[];
  final legacyRows = <({String id, String plaintext})>[];
  for (final row in rows) {
    final raw = row['auth_header'];
    var header = raw;
    if (raw is String) {
      header = await _sessionCrypto.decryptStored(raw);
      if (!SessionCrypto.isEncrypted(raw)) {
        legacyRows.add((id: row['id'] as String, plaintext: raw));
      }
    }
    accounts.add(Account.fromMap({...row, 'auth_header': header}));
  }

  if (legacyRows.isNotEmpty) {
    final upgrades = <({String id, String plaintext, String encrypted})>[];
    for (final legacy in legacyRows) {
      try {
        upgrades.add((
          id: legacy.id,
          plaintext: legacy.plaintext,
          encrypted: await _sessionCrypto.encrypt(legacy.plaintext),
        ));
      } catch (_) {
        // Reading an older install must still work if Keystore is unavailable.
      }
    }
    if (upgrades.isNotEmpty) {
      try {
        final database = await Repository.writable();
        for (final upgrade in upgrades) {
          await database.update(
            tableAccounts,
            {'auth_header': upgrade.encrypted},
            where: 'id = ? AND auth_header = ?',
            whereArgs: [upgrade.id, upgrade.plaintext],
          );
        }
      } catch (_) {
        // The compare-and-swap update is opportunistic, never a read dependency.
      }
    }
  }
  return accounts;
}

Future<List<Account>> getAccounts() => _readAccounts();

/// The account the app prefers for every request, or null when none is set
/// (the health-aware selector then decides alone).
Future<Account?> getActiveAccount() async {
  final accounts = await getAccounts();
  for (final account in accounts) {
    if (account.isActive) return account;
  }
  return null;
}

Future<String> _ensureLocalId(
  DatabaseExecutor database,
  Account account,
) async {
  if (account.localId.isNotEmpty && account.localId != account.id) {
    return account.localId;
  }

  // A row inserted before the column existed, or by a test helper that only
  // supplies the id, gets a real UUID on first use instead of keeping the ct0
  // as its owner key (which would orphan its likes on the next login).
  final localId = const Uuid().v4();
  await database.update(
    tableAccounts,
    {columnLocalId: localId},
    where: 'id = ?',
    whereArgs: [account.id],
  );
  return localId;
}

typedef _ActiveRow = ({
  String id,
  String? screenName,
  String? userId,
  String localId,
  bool sessionExpired,
});

Future<_ActiveRow?> _activeRowFrom(DatabaseExecutor database, String id) async {
  final rows = await database.query(
    tableAccounts,
    columns: ['screen_name', 'user_id', columnLocalId, columnLastAuthErrorAt],
    where: 'id = ?',
    whereArgs: [id],
  );
  if (rows.isEmpty) return null;
  final row = rows.first;
  final localId = await _ensureLocalId(
    database,
    Account(
      id: id,
      authHeader: '',
      screenName: row['screen_name'] as String?,
      userId: row['user_id'] as String?,
      localId: row[columnLocalId] as String?,
    ),
  );
  return (
    id: id,
    screenName: row['screen_name'] as String?,
    userId: _numericUserId(row['user_id'] as String?),
    localId: localId,
    sessionExpired: row[columnLastAuthErrorAt] != null,
  );
}

void _publishActive(_ActiveRow? row, {required bool bumpRevision}) {
  activeAccount.value = row == null
      ? null
      : ActiveAccount(
          id: row.id,
          screenName: row.screenName,
          userId: row.userId,
          localId: row.localId,
          sessionExpired: row.sessionExpired,
        );
  if (bumpRevision) accountsRevision.value++;
}

/// Fills [activeAccount] from the database. Called once during startup, before
/// the app builds: it does not touch [accountsRevision], so the feeds do not
/// reload over a value that was only being restored.
Future<void> loadActiveAccount() => _serialized(() async {
  final accounts = await _readAccounts(decryptHeaders: false);
  var account = accounts.where((candidate) => candidate.isActive).firstOrNull;
  final promote = account == null && accounts.isNotEmpty;
  if (promote) account = accounts.first;

  if (account == null) {
    activeAccount.value = null;
    return;
  }

  _ActiveRow? row;
  if (promote || account.localId.isEmpty || account.localId == account.id) {
    final database = await Repository.writable();
    row = await database.transaction((txn) async {
      if (promote) {
        await txn.update(tableAccounts, {
          'is_active': 0,
        }, where: 'is_active = 1');
        await txn.update(
          tableAccounts,
          {'is_active': 1},
          where: 'id = ?',
          whereArgs: [account!.id],
        );
      }
      return _activeRowFrom(txn, account!.id);
    });
  } else {
    row = (
      id: account.id,
      screenName: account.screenName,
      userId: _numericUserId(account.userId),
      localId: account.localId,
      sessionExpired: account.isSessionExpired,
    );
  }
  _publishActive(row, bumpRevision: false);
});

/// Switches the preferred account. The app then sends every request through it
/// first, falling back to the health logic when it is rate-limited/flagged.
/// Picking the account that is already active is a no-op unless [force] is set
/// (an import has to make sure the database flag agrees even when the in-memory
/// value happens to match).
Future<void> setActiveAccount(String id, {bool force = false}) =>
    _serialized(() => _setActiveAccountLocked(id, force: force));

Future<void> _setActiveAccountLocked(String id, {bool force = false}) async {
  if (!force && activeAccount.value?.id == id) return;

  final database = await Repository.writable();
  final row = await database.transaction((txn) async {
    await txn.update(tableAccounts, {'is_active': 0}, where: 'is_active = 1');
    await txn.update(
      tableAccounts,
      {'is_active': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
    return _activeRowFrom(txn, id);
  });
  // No await between the committed flag and the two publications: listeners of
  // activeAccount must see the new owner when accountsRevision fires.
  _publishActive(row, bumpRevision: true);
}

/// Remembers the account's numeric X id once a request needed it, so the next
/// launch (and the next tab opening) reads it from the database instead of
/// asking X again.
Future<void> setActiveAccountUserId(
  String userId, {
  String? expectedAccountId,
}) => _serialized(() async {
  final active = activeAccount.value;
  if (active == null) return;
  // A profile request can land after the reader switched accounts. Writing the
  // numeric id then would stamp the old login's id onto the new account, which
  // would show an empty Likes tab and mis-map a likes-vault export.
  if (expectedAccountId != null && active.id != expectedAccountId) return;

  final database = await Repository.writable();
  await database.update(
    tableAccounts,
    {'user_id': _numericUserId(userId)},
    where: 'id = ?',
    whereArgs: [active.id],
  );

  // The switch may have landed while the write was in flight; the old id must
  // not overwrite the new login in memory.
  if (activeAccount.value?.id != active.id) return;
  activeAccount.value = ActiveAccount(
    id: active.id,
    screenName: active.screenName,
    userId: _numericUserId(userId),
    localId: active.localId,
    sessionExpired: active.sessionExpired,
  );
});

List<Account> _identityMatches(
  List<Account> existing,
  String id,
  String? screenName,
  String? userId,
) {
  final numericId = _numericUserId(userId);
  if (numericId != null) {
    final byUser = existing
        .where((candidate) => _numericUserId(candidate.userId) == numericId)
        .toList();
    if (byUser.isNotEmpty) return _singleIdentityMatch(byUser);
    final byId = existing.where((candidate) => candidate.id == id).toList();
    if (byId.isEmpty) return const [];
    for (final candidate in byId) {
      final candidateUserId = _numericUserId(candidate.userId);
      if (candidateUserId != null && candidateUserId != numericId) {
        throw StateError(
          'The session token is already assigned to a different numeric user id',
        );
      }
    }
    return byId;
  }

  final byId = existing.where((candidate) => candidate.id == id).toList();
  if (byId.isNotEmpty) return _singleIdentityMatch(byId);
  final handle = _handleKey(screenName);
  if (handle == null) return const [];
  final byHandle = existing
      .where((candidate) => _handleKey(candidate.screenName) == handle)
      .toList();
  return _singleIdentityMatch(byHandle);
}

List<Account> _singleIdentityMatch(List<Account> matches) {
  if (matches.length > 1) {
    throw StateError('Multiple account rows match the same identity');
  }
  return matches;
}

/// Persists a fresh login and replaces any earlier row for the same numeric
/// user id. Only legacy rows without a numeric id may match by handle. X mints
/// a new ct0 on every login and the row is keyed by that token, so re-adding an
/// account used to leave the old row (and its expired session) behind.
///
/// The stable [Account.localId] is carried over: local likes attached to the
/// old row must survive a re-login.
Future<void> saveLoggedInAccount({
  required String id,
  required String screenName,
  String? userId,
  required String authHeader,
}) => _serialized(() async {
  final encryptedHeader = await _sessionCrypto.encrypt(authHeader);
  final numericId = _numericUserId(userId);
  final database = await Repository.writable();
  final saved = await database.transaction((txn) async {
    final existing = (await txn.query(tableAccounts))
        .map(Account.fromMap)
        .toList();
    final matches = _identityMatches(existing, id, screenName, numericId);
    final existingLocalId = matches
        .map((row) => row.localId)
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    if (existingLocalId.isNotEmpty &&
        existing.any(
          (row) => !matches.contains(row) && row.localId == existingLocalId,
        )) {
      throw StateError(
        'The matching account owner is also used by another row',
      );
    }
    final localId = existingLocalId.isNotEmpty
        ? existingLocalId
        : const Uuid().v4();
    final wasActive = matches.any((row) => row.isActive);

    for (final match in matches) {
      await txn.delete(tableAccounts, where: 'id = ?', whereArgs: [match.id]);
    }
    await txn.insert(
      tableAccounts,
      Account(
        id: id,
        screenName: screenName,
        userId: numericId,
        localId: localId,
        isActive: wasActive,
        authHeader: encryptedHeader,
      ).toMap(),
    );
    return wasActive ? _activeRowFrom(txn, id) : null;
  });
  if (saved != null) _publishActive(saved, bumpRevision: true);
});

/// Makes sure some account is active: called after a deletion, so an active
/// flag never lingers on an account that no longer exists.
Future<void> promoteFirstAccountIfNoneActive() => _serialized(() async {
  final accounts = await _readAccounts(decryptHeaders: false);
  if (accounts.isEmpty) {
    if (activeAccount.value != null) _publishActive(null, bumpRevision: true);
    return;
  }
  if (accounts.any((account) => account.isActive)) return;
  await _setActiveAccountLocked(accounts.first.id);
});

/// Removes an account together with the local likes owned by it. The owner is
/// read in the same transaction as the deletes, so a concurrent re-login cannot
/// move the row between those two steps.
Future<void> deleteAccountAndLocalLikes(String id) => _serialized(() async {
  final database = await Repository.writable();
  final (wasActive, next) = await database.transaction((txn) async {
    final rows = await txn.query(
      tableAccounts,
      columns: [columnLocalId, 'is_active'],
      where: 'id = ?',
      whereArgs: [id],
    );
    final localId = rows.isEmpty ? null : rows.first[columnLocalId] as String?;
    final active = rows.isNotEmpty && rows.first['is_active'] == 1;
    if (localId != null) {
      await txn.delete(
        tableAccountLike,
        where: '$columnAccountLocalId = ?',
        whereArgs: [localId],
      );
    }
    await txn.delete(tableAccounts, where: 'id = ?', whereArgs: [id]);
    await txn.rawDelete('''
          DELETE FROM $tableLikedTweet
          WHERE id NOT IN (SELECT DISTINCT $columnTweetId FROM $tableAccountLike)
        ''');
    if (!active) return (false, null);
    final replacement = (await txn.query(
      tableAccounts,
      orderBy: 'screen_name COLLATE NOCASE',
      limit: 1,
    )).firstOrNull;
    if (replacement == null) return (true, null);
    await txn.update(tableAccounts, {'is_active': 0}, where: 'is_active = 1');
    await txn.update(
      tableAccounts,
      {'is_active': 1},
      where: 'id = ?',
      whereArgs: [replacement['id']],
    );
    return (true, await _activeRowFrom(txn, replacement['id'] as String));
  });
  if (wasActive) _publishActive(next, bumpRevision: true);
});

/// Increment the consecutive-404 counter, flagging the account as not found only
/// once it has thrown [notFoundThreshold] 404s in a row.
Future<void> recordNotFound(String id) async {
  var database = await Repository.writable();
  await database.rawUpdate(
    '''
    UPDATE $tableAccounts SET
      consecutive_not_found = consecutive_not_found + 1,
      last_not_found_at = CASE WHEN consecutive_not_found + 1 >= $notFoundThreshold
        THEN ? ELSE last_not_found_at END
    WHERE id = ?''',
    [DateTime.now().toIso8601String(), id],
  );
}

/// Records a 401 for this account. A session that X has revoked should not be
/// retried on every request, and the account sheet needs to tell the reader
/// which login needs a fresh sign-in.
Future<void> recordAuthFailure(String id) async {
  final database = await Repository.writable();
  await database.update(
    tableAccounts,
    {columnLastAuthErrorAt: DateTime.now().toIso8601String()},
    where: 'id = ?',
    whereArgs: [id],
  );

  final active = activeAccount.value;
  if (active == null || active.id != id || active.sessionExpired) return;
  activeAccount.value = ActiveAccount(
    id: active.id,
    screenName: active.screenName,
    userId: active.userId,
    localId: active.localId,
    sessionExpired: true,
  );
}

/// Clears the not-found flags after a successful response. When
/// [requestStartedAt] is supplied, the session failure is cleared only if it
/// predates that request; an older in-flight 200 must not erase a newer 401.
/// Returns whether the account row matched the session-clear condition.
Future<bool> recordAccountSuccess(
  String id, {
  DateTime? requestStartedAt,
}) async {
  try {
    return await _recordAccountSuccess(id, requestStartedAt: requestStartedAt);
  } catch (_) {
    // Health writes are best-effort. A failed write did not clear the row, and
    // existing callers fire this Future without awaiting its error.
    return false;
  }
}

Future<bool> _recordAccountSuccess(
  String id, {
  required DateTime? requestStartedAt,
}) async {
  final database = await Repository.writable();
  final bool cleared;
  if (requestStartedAt == null) {
    final changed = await database.update(
      tableAccounts,
      {
        'consecutive_not_found': 0,
        'last_not_found_at': null,
        columnLastAuthErrorAt: null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    cleared = changed > 0;
  } else {
    await database.update(
      tableAccounts,
      {'consecutive_not_found': 0, 'last_not_found_at': null},
      where: 'id = ?',
      whereArgs: [id],
    );
    final changed = await database.update(
      tableAccounts,
      {columnLastAuthErrorAt: null},
      where:
          'id = ? AND '
          '($columnLastAuthErrorAt IS NULL OR $columnLastAuthErrorAt <= ?)',
      whereArgs: [id, requestStartedAt.toIso8601String()],
    );
    cleared = changed > 0;
  }

  if (!cleared) return false;
  final active = activeAccount.value;
  if (active == null || active.id != id || !active.sessionExpired) return true;
  activeAccount.value = ActiveAccount(
    id: active.id,
    screenName: active.screenName,
    userId: active.userId,
    localId: active.localId,
    sessionExpired: false,
  );
  return true;
}

/// Caches the profile fields the account switcher draws. Called once after a
/// login, and lazily for accounts that predate the columns.
Future<void> updateAccountProfile(
  String id, {
  required String? displayName,
  required String? avatarUrl,
}) async {
  final database = await Repository.writable();
  await database.update(
    tableAccounts,
    {
      columnDisplayName: displayName,
      columnAvatarUrl: avatarUrl,
      columnProfileFetchedAt: DateTime.now().toIso8601String(),
    },
    where: 'id = ?',
    whereArgs: [id],
  );
}

class AccountImportResult {
  final int imported;
  final int replaced;
  final int kept;

  const AccountImportResult({
    required this.imported,
    required this.replaced,
    required this.kept,
  });

  int get total => imported + replaced + kept;

  /// Accounts the restore actually wrote: new rows plus rows whose session was
  /// replaced. A kept row is unchanged, so it must not read as "restored".
  int get restored => imported + replaced;
}

/// Merges accounts read from a vault into the database.
///
/// An account that already exists keeps its current session unless
/// [replaceExisting] is true. Its stable local id is always preserved, so the
/// likes saved while it was logged in stay attached. The backup's preferred
/// account becomes active afterwards, which resets the feeds on an explicit
/// restore.
Future<AccountImportResult> importAccounts(
  List<Account> accounts, {
  bool replaceExisting = false,
}) => _serialized(() async {
  final unique = <String, Account>{};
  for (final account in accounts) {
    final handle = _handleKey(account.screenName);
    if (handle == null) continue;
    final numericId = _numericUserId(account.userId);
    final key = numericId == null ? 'h:$handle' : 'u:$numericId';
    final previous = unique[key];
    if (previous != null) {
      if (_handleKey(previous.screenName) != handle ||
          previous.localId != account.localId ||
          previous.id != account.id) {
        throw StateError(
          'The backup contains conflicting rows for one account identity',
        );
      }
      continue;
    }
    unique[key] = account;
  }
  if (unique.isEmpty) {
    return const AccountImportResult(imported: 0, replaced: 0, kept: 0);
  }

  var imported = 0;
  var replaced = 0;
  var kept = 0;
  final database = await Repository.writable();
  final preferred = await database.transaction((txn) async {
    final existing = (await txn.query(tableAccounts))
        .map(Account.fromMap)
        .toList();
    final usedLocalIds = existing.map((row) => row.localId).toSet();

    for (final account in unique.values) {
      final numericId = _numericUserId(account.userId);
      final matches = _identityMatches(
        existing,
        account.id,
        account.screenName,
        numericId,
      );
      if (matches.isNotEmpty) {
        final match = matches.single;
        if (!replaceExisting) {
          kept++;
          continue;
        }
        var localId = match.localId;
        if (localId.isEmpty || localId == match.id) localId = const Uuid().v4();
        if (existing.any(
          (row) => row.id != match.id && row.localId == localId,
        )) {
          throw StateError(
            'The matching account owner is also used by another row',
          );
        }
        await txn.delete(tableAccounts, where: 'id = ?', whereArgs: [match.id]);
        await txn.insert(
          tableAccounts,
          Account(
            id: account.id,
            authHeader: await _sessionCrypto.encrypt(
              account.authHeader.toString(),
            ),
            screenName: account.screenName,
            userId: numericId ?? match.userId,
            localId: localId,
            isActive: match.isActive,
          ).toMap(),
        );
        existing.remove(match);
        existing.add(
          Account(
            id: account.id,
            authHeader: '',
            screenName: account.screenName,
            userId: numericId ?? match.userId,
            localId: localId,
            isActive: match.isActive,
          ),
        );
        replaced++;
        continue;
      }

      var localId = account.localId;
      if (localId.isEmpty || usedLocalIds.contains(localId)) {
        localId = const Uuid().v4();
      }
      usedLocalIds.add(localId);
      await txn.insert(
        tableAccounts,
        Account(
          id: account.id,
          authHeader: await _sessionCrypto.encrypt(
            account.authHeader.toString(),
          ),
          screenName: account.screenName,
          userId: numericId,
          localId: localId,
        ).toMap(),
      );
      existing.add(
        Account(
          id: account.id,
          authHeader: '',
          screenName: account.screenName,
          userId: numericId,
          localId: localId,
        ),
      );
      imported++;
    }

    final selected = unique.values.firstWhere(
      (account) => account.isActive,
      orElse: () => unique.values.first,
    );
    final numericId = _numericUserId(selected.userId);
    List<Account> candidates;
    if (numericId != null) {
      candidates = existing
          .where((account) => _numericUserId(account.userId) == numericId)
          .toList();
    } else {
      candidates = existing
          .where(
            (account) =>
                account.id == selected.id ||
                _handleKey(account.screenName) ==
                    _handleKey(selected.screenName),
          )
          .toList();
    }
    if (candidates.length > 1) {
      throw StateError('The restored preferred account is ambiguous');
    }
    final target = candidates.firstOrNull;
    if (target == null) return null;
    await txn.update(tableAccounts, {'is_active': 0}, where: 'is_active = 1');
    await txn.update(
      tableAccounts,
      {'is_active': 1},
      where: 'id = ?',
      whereArgs: [target.id],
    );
    return _activeRowFrom(txn, target.id);
  });
  _publishActive(preferred, bumpRevision: true);
  return AccountImportResult(
    imported: imported,
    replaced: replaced,
    kept: kept,
  );
});
