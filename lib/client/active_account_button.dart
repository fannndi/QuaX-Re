import 'package:material_ui/material_ui.dart';
import 'package:quax/client/account_sheet.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/generated/l10n.dart';

/// The home app bar's account button: the initial of the active handle, so a
/// glance says which login the feed belongs to. Tapping it opens the switcher.
class ActiveAccountButton extends StatelessWidget {
  const ActiveAccountButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ActiveAccount?>(
      valueListenable: activeAccount,
      builder: (context, account, _) {
        final handle = account?.handle;
        final scheme = Theme.of(context).colorScheme;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            IconButton(
              tooltip: handle == null ? L10n.of(context).account : '@$handle',
              onPressed: () => showAccountSwitcher(context),
              icon: account == null
                  ? const Icon(Icons.person_outline)
                  : CircleAvatar(
                      radius: 13,
                      backgroundColor: scheme.primaryContainer,
                      child: Text(
                        handle == null ? '?' : handle[0].toUpperCase(),
                        style: Theme.of(context)
                            .textTheme
                            .labelLarge
                            ?.copyWith(color: scheme.onPrimaryContainer),
                      ),
                    ),
            ),
            if (account?.sessionExpired ?? false)
              Positioned(
                right: 6,
                top: 6,
                child: IgnorePointer(
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: scheme.error, shape: BoxShape.circle),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
