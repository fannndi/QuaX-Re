import 'package:quax/client/accounts.dart';
import 'package:quax/client/client.dart';
import 'package:quax/database/entities.dart';

/// Fetches and caches the display name and avatar the account tile draws.
///
/// The request goes through the normal client, so it follows the same account
/// selection and rate-limit rules as a profile screen. A fetched row is kept
/// for [maxAge]; a failed fetch leaves the timestamp empty and is retried the
/// next time the tile mounts.
class AccountProfileCache {
  static const maxAge = Duration(days: 30);
  static final Set<String> _inFlight = {};

  static Future<Account?> ensure(Account account) async {
    final handle = account.screenName;
    if (handle == null || handle.isEmpty) return null;

    final fetchedAt = account.profileFetchedAt;
    if (fetchedAt != null && DateTime.now().difference(fetchedAt) < maxAge) {
      return null;
    }
    if (!_inFlight.add(account.id)) return null;

    try {
      final profile = await Twitter.getProfileByScreenName(handle);
      final avatarUrl = profile.user.profileImageUrlHttps;
      final displayName = profile.user.name;
      final now = DateTime.now();
      await updateAccountProfile(account.id, displayName: displayName, avatarUrl: avatarUrl);
      return account.copyWithProfile(
        displayName: displayName,
        avatarUrl: avatarUrl,
        profileFetchedAt: now,
      );
    } catch (_) {
      // Offline or a rate-limited profile request: the initials remain.
      return null;
    } finally {
      _inFlight.remove(account.id);
    }
  }
}
