import 'package:material_ui/material_ui.dart';
import 'package:quax/client/account_profile_cache.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/generated/l10n.dart';

/// One account row shared by the switcher sheet and the account manager.
///
/// The real avatar and display name are fetched lazily and cached in the
/// account row; the initials are the offline fallback. A 401 produces a
/// session-expired line and a re-login action instead of pretending the login
/// still works.
class AccountTile extends StatefulWidget {
  final Account account;
  final bool dense;
  final VoidCallback? onTap;
  final VoidCallback? onRelogin;
  final Widget? trailing;

  const AccountTile({
    super.key,
    required this.account,
    this.dense = false,
    this.onTap,
    this.onRelogin,
    this.trailing,
  });

  @override
  State<AccountTile> createState() => _AccountTileState();
}

class _AccountTileState extends State<AccountTile> {
  late Account _account = widget.account;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void didUpdateWidget(AccountTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.account;
    final current = widget.account;
    if (old.id != current.id) {
      _account = current;
      _loadProfile();
      return;
    }
    if (old.avatarUrl != current.avatarUrl ||
        old.displayName != current.displayName ||
        old.isActive != current.isActive ||
        old.lastAuthErrorAt != current.lastAuthErrorAt) {
      _account = current;
    }
  }

  Future<void> _loadProfile() async {
    final updated = await AccountProfileCache.ensure(_account);
    if (mounted && updated != null) {
      setState(() => _account = updated);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final handle = _account.screenName == null ? '?' : '@${_account.screenName}';
    final hasName = _account.displayName?.isNotEmpty == true;
    final expired = _account.isSessionExpired;
    final title = hasName ? _account.displayName! : handle;

    return ListTile(
      dense: widget.dense,
      leading: _avatar(),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: hasName || expired
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hasName) Text(handle, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (expired)
                  Text(l10n.session_expired,
                      style: TextStyle(color: scheme.error, fontSize: 12)),
              ],
            )
          : null,
      isThreeLine: hasName && expired,
      selected: _account.isActive,
      onTap: widget.onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (expired && widget.onRelogin != null)
            IconButton(
              icon: const Icon(Icons.login),
              tooltip: l10n.login_again,
              onPressed: widget.onRelogin,
            ),
          if (_account.isActive)
            Icon(Icons.check_circle_outline, size: 20, color: scheme.primary),
          if (widget.trailing != null) widget.trailing!,
        ],
      ),
    );
  }

  Widget _avatar() {
    final handle = _account.screenName;
    final initial = handle == null || handle.isEmpty ? '?' : handle[0].toUpperCase();
    final radius = widget.dense ? 16.0 : 18.0;
    final fallback = CircleAvatar(
      radius: radius,
      child: Text(initial),
    );

    final url = _account.avatarUrl;
    if (url == null || url.isEmpty) return fallback;
    return ClipOval(
      child: Image.network(
        url,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        cacheWidth: 96,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}
