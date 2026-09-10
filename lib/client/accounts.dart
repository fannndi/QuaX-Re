import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:quax/client/account_selector.dart';
import 'package:quax/constants.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';

/// Bumped whenever the preferred account changes, so feeds can reload against
/// the new account without knowing the settings screen exists.
final ValueNotifier<int> accountsRevision = ValueNotifier<int>(0);

Future<List<Account>> getAccounts() async {
  var database = await Repository.readOnly();
  var query = await database.query(tableAccounts);
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

/// Switches the preferred account. The app then sends every request through it
/// first, falling back to the health logic when it is rate-limited/flagged.
Future<void> setActiveAccount(String id) async {
  var database = await Repository.writable();
  await database.transaction((txn) async {
    await txn.update(tableAccounts, {'is_active': 0}, where: 'is_active = 1');
    await txn.update(tableAccounts, {'is_active': 1}, where: 'id = ?', whereArgs: [id]);
  });
  accountsRevision.value++;
}

/// Makes sure some account is active: called after a deletion, so an active
/// flag never lingers on an account that no longer exists.
Future<void> promoteFirstAccountIfNoneActive() async {
  final accounts = await getAccounts();
  if (accounts.isEmpty || accounts.any((a) => a.isActive)) return;
  await setActiveAccount(accounts.first.id);
}

/// Decoded auth header for a single healthy account, or null if none is usable.
/// Used by one-shot requests (e.g. translation) that don't drive the retry loop.
Future<Map<dynamic, dynamic>?> pickAuthHeader() async {
  final accounts = await getAccounts();
  final account = AccountSelector(accounts, DateTime.now()).pick(exclude: <String>{});
  if (account == null) {
    return null;
  }
  return json.decode(account.authHeader);
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

/// Clear the not-found flag after a successful response for the account.
Future<void> recordAccountSuccess(String id) async {
  var database = await Repository.writable();
  await database.update(
      tableAccounts,
      {
        'consecutive_not_found': 0,
        'last_not_found_at': null,
      },
      where: 'id = ?',
      whereArgs: [id]);
}
