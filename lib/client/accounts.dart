import 'package:flutter/foundation.dart';
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

  const ActiveAccount(
      {required this.id,
      this.screenName,
      this.userId,
      String? localId,
      this.sessionExpired = false})
      : localId = localId ?? id;

  String? get handle => screenName == null || screenName!.isEmpty ? null : screenName;
}

final ValueNotifier<ActiveAccount?> activeAccount = ValueNotifier<ActiveAccount?>(null);

Future<List<Account>> getAccounts() async {
  final query = await Repository.read((db) => db.query(tableAccounts,
      orderBy: 'is_active DESC, screen_name COLLATE NOCASE'));
  return List.from(query).map((e) => Account.fromMap(e)).toList();
}

/// The account the app prefers for every request, or null when none is set
/// (the health-aware selector then decides alone).
Future<Account?> getActiveAccount() async {
  final accounts = await getAccounts();
  for (final account in accounts) {
    if (account.isActive) return account;
  }
  return null;
}

Future<String> _ensureLocalId(Database database, Account account) async {
  if (account.localId.isNotEmpty && account.localId != account.id) {
    return account.localId;
  }

  // A row inserted before the column existed, or by a test helper that only
  // supplies the id, gets a real UUID on first use instead of keeping the ct0
  // as its owner key (which would orphan its likes on the next login).
  final localId = const Uuid().v4();
  await database.update(tableAccounts, {columnLocalId: localId},
      where: 'id = ?', whereArgs: [account.id]);
  return localId;
}

/// Fills [activeAccount] from the database. Called once during startup, before
/// the app builds: it does not touch [accountsRevision], so the feeds do not
/// reload over a value that was only being restored.
Future<void> loadActiveAccount() async {
  final accounts = await getAccounts();
  Account? account;
  for (final candidate in accounts) {
    if (candidate.isActive) {
      account = candidate;
      break;
    }
  }

  // A re-login can delete the active row while its replacement is inserted
  // before the new flag is written. If that window is interrupted, every
  // account-scoped feed would report "no account" even though the sessions are
  // still in the database. Promote the first row instead of leaving it broken.
  if (account == null && accounts.isNotEmpty) {
    account = accounts.first;
    final accountId = account.id;
    final database = await Repository.writable();
    await database.transaction((txn) async {
      await txn.update(tableAccounts, {'is_active': 0}, where: 'is_active = 1');
      await txn.update(tableAccounts, {'is_active': 1}, where: 'id = ?', whereArgs: [accountId]);
    });
  }

  if (account == null) {
    activeAccount.value = null;
    return;
  }

  final database = await Repository.writable();
  final localId = await _ensureLocalId(database, account);
  activeAccount.value = ActiveAccount(
      id: account.id,
      screenName: account.screenName,
      userId: account.userId,
      localId: localId,
      sessionExpired: account.isSessionExpired);
}

/// Switches the preferred account. The app then sends every request through it
/// first, falling back to the health logic when it is rate-limited/flagged.
/// Picking the account that is already active is a no-op unless [force] is set
/// (an import has to make sure the database flag agrees even when the in-memory
/// value happens to match).
Future<void> setActiveAccount(String id, {bool force = false}) async {
  if (!force && activeAccount.value?.id == id) return;

  var database = await Repository.writable();
  await database.transaction((txn) async {
    await txn.update(tableAccounts, {'is_active': 0}, where: 'is_active = 1');
    await txn.update(tableAccounts, {'is_active': 1}, where: 'id = ?', whereArgs: [id]);
  });

  final rows = await database.query(tableAccounts,
      columns: ['screen_name', 'user_id', columnLocalId, columnLastAuthErrorAt],
      where: 'id = ?',
      whereArgs: [id]);
  if (rows.isEmpty) {
    activeAccount.value = null;
    accountsRevision.value++;
    return;
  }

  final row = rows.first;
  final localId = await _ensureLocalId(
      database,
      Account(
          id: id,
          authHeader: '',
          screenName: row['screen_name'] as String?,
          userId: row['user_id'] as String?,
          localId: row[columnLocalId] as String?));

  activeAccount.value = ActiveAccount(
      id: id,
      screenName: row['screen_name'] as String?,
      userId: row['user_id'] as String?,
      localId: localId,
      sessionExpired: row[columnLastAuthErrorAt] != null);
  accountsRevision.value++;
}

/// Remembers the account's numeric X id once a request needed it, so the next
/// launch (and the next tab opening) reads it from the database instead of
/// asking X again.
Future<void> setActiveAccountUserId(String userId, {String? expectedAccountId}) async {
  final active = activeAccount.value;
  if (active == null) return;
  // A profile request can land after the reader switched accounts. Writing the
  // numeric id then would stamp the old login's id onto the new account, which
  // would show an empty Likes tab and mis-map a likes-vault export.
  if (expectedAccountId != null && active.id != expectedAccountId) return;

  var database = await Repository.writable();
  await database.update(tableAccounts, {'user_id': userId}, where: 'id = ?', whereArgs: [active.id]);

  activeAccount.value = ActiveAccount(
      id: active.id,
      screenName: active.screenName,
      userId: userId,
      localId: active.localId,
      sessionExpired: active.sessionExpired);
}

/// Persists a fresh login and replaces any earlier row for the same handle or
/// numeric id. X mints a new ct0 on every login and the row is keyed by that
/// token, so re-adding an account used to leave the old row (and its expired
/// session) behind as a second account.
///
/// The stable [Account.localId] is carried over: local likes attached to the
/// old row must survive a re-login.
Future<void> saveLoggedInAccount({
  required String id,
  required String screenName,
  String? userId,
  required String authHeader,
}) async {
  final database = await Repository.writable();
  await database.transaction((txn) async {
    // Prefer the identity match over the ct0 match: the whole point is that a
    // re-login gets a new ct0 but should keep the same local owner.
    final identityWhere = userId == null ? 'screen_name = ?' : 'screen_name = ? OR user_id = ?';
    final identityArgs = userId == null ? [screenName] : [screenName, userId];
    final matchWhere = '($identityWhere) OR id = ?';
    final matchArgs = [...identityArgs, id];
    final existing = await txn.query(tableAccounts,
        columns: [columnLocalId, 'is_active'], where: matchWhere, whereArgs: matchArgs);
    final existingLocalId = existing
        .map((row) => row[columnLocalId] as String?)
        .firstWhere((value) => value != null && value.isNotEmpty, orElse: () => null);
    final wasActive = existing.any((row) => row['is_active'] == 1);
    final localId = existingLocalId ?? const Uuid().v4();

    await txn.delete(tableAccounts, where: matchWhere, whereArgs: matchArgs);
    await txn.insert(
      tableAccounts,
      Account(
        id: id,
        screenName: screenName,
        userId: userId,
        localId: localId,
        isActive: wasActive,
        authHeader: authHeader,
      ).toMap(),
    );
  });
}

/// Makes sure some account is active: called after a deletion, so an active
/// flag never lingers on an account that no longer exists.
Future<void> promoteFirstAccountIfNoneActive() async {
  final accounts = await getAccounts();
  if (accounts.isEmpty) {
    if (activeAccount.value != null) {
      activeAccount.value = null;
      accountsRevision.value++;
    }
    return;
  }
  if (accounts.any((a) => a.isActive)) return;
  await setActiveAccount(accounts.first.id);
}

/// Removes an account together with the local likes owned by it. The tweet
/// bodies those likes cached are deleted only when no other account still
/// references them.
Future<void> deleteAccountAndLocalLikes(String id) async {
  final database = await Repository.writable();
  final rows = await database.query(tableAccounts, columns: [columnLocalId], where: 'id = ?', whereArgs: [id]);
  final localId = rows.isEmpty ? null : rows.first[columnLocalId] as String?;

  await database.transaction((txn) async {
    if (localId != null) {
      await txn.delete(tableAccountLike, where: '$columnAccountLocalId = ?', whereArgs: [localId]);
    }
    await txn.delete(tableAccounts, where: 'id = ?', whereArgs: [id]);
    await txn.rawDelete('''
      DELETE FROM $tableLikedTweet
      WHERE id NOT IN (SELECT DISTINCT $columnTweetId FROM $tableAccountLike)
    ''');
  });

  if (activeAccount.value?.id == id) {
    await promoteFirstAccountIfNoneActive();
  }
}

/// Increment the consecutive-404 counter, flagging the account as not found only
/// once it has thrown [notFoundThreshold] 404s in a row.
Future<void> recordNotFound(String id) async {
  var database = await Repository.writable();
  await database.rawUpdate('''
    UPDATE $tableAccounts SET
      consecutive_not_found = consecutive_not_found + 1,
      last_not_found_at = CASE WHEN consecutive_not_found + 1 >= $notFoundThreshold
        THEN ? ELSE last_not_found_at END
    WHERE id = ?''', [DateTime.now().toIso8601String(), id]);
}

/// Records a 401 for this account. A session that X has revoked should not be
/// retried on every request, and the account sheet needs to tell the reader
/// which login needs a fresh sign-in.
Future<void> recordAuthFailure(String id) async {
  final database = await Repository.writable();
  await database.update(tableAccounts, {columnLastAuthErrorAt: DateTime.now().toIso8601String()},
      where: 'id = ?', whereArgs: [id]);

  final active = activeAccount.value;
  if (active == null || active.id != id || active.sessionExpired) return;
  activeAccount.value = ActiveAccount(
      id: active.id,
      screenName: active.screenName,
      userId: active.userId,
      localId: active.localId,
      sessionExpired: true);
}

/// Clear the not-found and session flags after a successful response for the
/// account.
Future<void> recordAccountSuccess(String id) async {
  var database = await Repository.writable();
  await database.update(
      tableAccounts,
      {
        'consecutive_not_found': 0,
        'last_not_found_at': null,
        columnLastAuthErrorAt: null,
      },
      where: 'id = ?',
      whereArgs: [id]);

  final active = activeAccount.value;
  if (active == null || active.id != id || !active.sessionExpired) return;
  activeAccount.value = ActiveAccount(
      id: active.id,
      screenName: active.screenName,
      userId: active.userId,
      localId: active.localId,
      sessionExpired: false);
}

/// Caches the profile fields the account switcher draws. Called once after a
/// login, and lazily for accounts that predate the columns.
Future<void> updateAccountProfile(String id,
    {required String? displayName, required String? avatarUrl}) async {
  final database = await Repository.writable();
  await database.update(
      tableAccounts,
      {
        columnDisplayName: displayName,
        columnAvatarUrl: avatarUrl,
        columnProfileFetchedAt: DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id]);
}

class AccountImportResult {
  final int imported;
  final int replaced;
  final int kept;
  final List<String> skipped;

  const AccountImportResult({
    required this.imported,
    required this.replaced,
    required this.kept,
    this.skipped = const [],
  });

  int get total => imported + replaced + kept;
}

/// Merges accounts read from a vault into the database.
///
/// An account that already exists keeps its current session unless
/// [replaceExisting] is true. Its stable local id is always preserved, so the
/// likes saved while it was logged in stay attached. The backup's preferred
/// account becomes active afterwards, which resets the feeds on an explicit
/// restore.
Future<AccountImportResult> importAccounts(List<Account> accounts,
    {bool replaceExisting = false}) async {
  final unique = <Account>[];
  final seen = <String>{};
  for (final account in accounts) {
    final handle = account.screenName;
    if (handle == null || handle.isEmpty) continue;
    final key = account.userId == null ? 'h:${handle.toLowerCase()}' : 'u:${account.userId}';
    if (seen.add(key)) unique.add(account);
  }
  if (unique.isEmpty) {
    return const AccountImportResult(imported: 0, replaced: 0, kept: 0);
  }

  var imported = 0;
  var replaced = 0;
  var kept = 0;
  final skipped = <String>[];
  final database = await Repository.writable();

  await database.transaction((txn) async {
    final existingRows = await txn.query(tableAccounts);
    final existing = existingRows.map((e) => Account.fromMap(e)).toList();
    final usedLocalIds = existing.map((e) => e.localId).toSet();

    for (final account in unique) {
      Account? match;
      for (final candidate in existing) {
        final sameId = candidate.id == account.id;
        final sameUser = account.userId != null && candidate.userId == account.userId;
        final sameHandle = candidate.screenName?.toLowerCase() == account.screenName?.toLowerCase();
        if (sameId || sameUser || sameHandle) {
          match = candidate;
          break;
        }
      }

      if (match != null) {
        if (!replaceExisting) {
          kept++;
          continue;
        }
        final localId = match.localId;
        final wasActive = match.isActive;
        await txn.delete(tableAccounts, where: 'id = ?', whereArgs: [match.id]);
        await txn.insert(
          tableAccounts,
          Account(
            id: account.id,
            authHeader: account.authHeader,
            screenName: account.screenName,
            userId: account.userId ?? match.userId,
            localId: localId,
            isActive: wasActive,
          ).toMap(),
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
          authHeader: account.authHeader,
          screenName: account.screenName,
          userId: account.userId,
          localId: localId,
        ).toMap(),
      );
      imported++;
    }
  });

  final preferred = unique.firstWhere((a) => a.isActive, orElse: () => unique.first);
  var rows = <Map<String, Object?>>[];
  if (preferred.userId != null) {
    rows = await database.query(tableAccounts,
        where: 'user_id = ?', whereArgs: [preferred.userId], limit: 1);
  }
  if (rows.isEmpty) {
    rows = await database.query(tableAccounts,
        where: 'screen_name = ? COLLATE NOCASE', whereArgs: [preferred.screenName], limit: 1);
  }

  if (rows.isEmpty) {
    await promoteFirstAccountIfNoneActive();
  } else {
    if (activeAccount.value == null) {
      await loadActiveAccount();
    }
    await setActiveAccount(rows.first['id'] as String, force: true);
  }

  return AccountImportResult(
    imported: imported,
    replaced: replaced,
    kept: kept,
    skipped: skipped,
  );
}
