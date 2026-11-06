import 'package:quax/database/repository.dart';

mixin ToMappable {
  Map<String, dynamic> toMap();
}

class LikedTweet with ToMappable {
  final String id;
  final String? user;
  final String? content;

  LikedTweet({required this.id, required this.user, required this.content});

  factory LikedTweet.fromMap(Map<String, Object?> map) {
    return LikedTweet(
        id: map['id'] as String, user: map['user_id'] as String?, content: map['content'] as String?);
  }

  @override
  Map<String, dynamic> toMap() {
    return {'id': id, 'content': content, 'user_id': user};
  }
}

class Account with ToMappable {
  final String id;
  final dynamic authHeader;
  final String? screenName;
  // The numeric X user id (rest_id). The Likes endpoint takes it as `userId` —
  // x.com's likes tab sends it, and X answers nothing for anything else. Null
  // until the login page or a profile request fills it in.
  final String? userId;
  // Stable across a re-login: X mints a new ct0 every time, but the local likes
  // (and any future per-account data) stay attached to this id.
  final String localId;
  final DateTime? lastNotFoundAt;
  final int consecutiveNotFound;
  // The account the app prefers for every request; health still wins when the
  // active one is rate-limited or flagged.
  final bool isActive;
  // Set only by a 401. A 404 usually means a rotated queryId or a deleted
  // profile, so it must not be presented as an expired session.
  final DateTime? lastAuthErrorAt;
  final String? avatarUrl;
  final String? displayName;
  final DateTime? profileFetchedAt;

  const Account(
      {required this.id,
      required this.authHeader,
      required this.screenName,
      this.userId,
      String? localId,
      this.lastNotFoundAt,
      this.consecutiveNotFound = 0,
      this.isActive = false,
      this.lastAuthErrorAt,
      this.avatarUrl,
      this.displayName,
      this.profileFetchedAt})
      : localId = localId ?? id;

  static DateTime? _date(Object? value) => value == null ? null : DateTime.parse(value as String);

  /// No flag set, so a successful response needs no database write (hot-path guard).
  bool get isClean =>
      consecutiveNotFound == 0 && lastNotFoundAt == null && lastAuthErrorAt == null;

  bool get isSessionExpired => lastAuthErrorAt != null;

  factory Account.fromMap(Map<String, Object?> map) {
    return Account(
        id: map['id'] as String,
        authHeader: map['auth_header'],
        screenName: map['screen_name'] as String?,
        userId: map['user_id'] as String?,
        localId: map[columnLocalId] as String?,
        lastNotFoundAt: _date(map['last_not_found_at']),
        consecutiveNotFound: (map['consecutive_not_found'] as int?) ?? 0,
        isActive: (map['is_active'] as int?) == 1,
        lastAuthErrorAt: _date(map[columnLastAuthErrorAt]),
        avatarUrl: map[columnAvatarUrl] as String?,
        displayName: map[columnDisplayName] as String?,
        profileFetchedAt: _date(map[columnProfileFetchedAt]));
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Account && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'auth_header': authHeader,
      'screen_name': screenName,
      'user_id': userId,
      columnLocalId: localId,
      'last_not_found_at': lastNotFoundAt?.toIso8601String(),
      'consecutive_not_found': consecutiveNotFound,
      'is_active': isActive ? 1 : 0,
      columnLastAuthErrorAt: lastAuthErrorAt?.toIso8601String(),
      columnAvatarUrl: avatarUrl,
      columnDisplayName: displayName,
      columnProfileFetchedAt: profileFetchedAt?.toIso8601String(),
    };
  }
}
