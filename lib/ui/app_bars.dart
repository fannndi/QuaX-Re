import 'package:material_ui/material_ui.dart';
import 'package:quax/app/design_tokens.dart';

/// The second row of a tabbed screen: the tabs take the width they need and
/// every trailing action keeps a 48dp slot, so a screen never shifts when a
/// conditional action appears or disappears.
class AppTabsRow extends StatelessWidget {
  final TabBar tabBar;
  final List<Widget> actions;

  const AppTabsRow({super.key, required this.tabBar, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppSize.tabBar,
      child: Row(
        children: [
          Expanded(child: tabBar),
          ...actions,
          const SizedBox(width: AppSpace.sm),
        ],
      ),
    );
  }
}

PreferredSizeWidget appBarBottom(Widget child) => PreferredSize(
  preferredSize: const Size.fromHeight(AppSize.tabBar),
  child: child,
);

/// A hairline under the app bar is enough separation on a monochrome surface;
/// no elevation or tint is needed.
ShapeBorder appBarBorder(BuildContext context) => Border(
  bottom: BorderSide(
    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.7),
  ),
);
