import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:quax/group/feed_refresh_controller.dart';
import 'package:quax/ui/app_bars.dart';

class GroupFeedShell extends StatefulWidget {
  final ScrollController scrollController;
  final Widget? leading;
  final WidgetBuilder titleBuilder;
  final PreferredSizeWidget? bottom;
  final WidgetBuilder bodyBuilder;
  final List<Widget> Function(BuildContext) actionsBuilder;

  const GroupFeedShell({
    super.key,
    required this.scrollController,
    required this.titleBuilder,
    required this.bodyBuilder,
    required this.actionsBuilder,
    this.leading,
    this.bottom,
  });

  @override
  State<GroupFeedShell> createState() => _GroupFeedShellState();
}

class _GroupFeedShellState extends State<GroupFeedShell>
    with AutomaticKeepAliveClientMixin<GroupFeedShell> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Provider<FeedRefreshController>.value(
      value: context.read<FeedRefreshController>(),
      child: NestedScrollView(
        controller: widget.scrollController,
        floatHeaderSlivers: false,
        headerSliverBuilder: (context, innerBoxIsScrolled) {
          return [
            SliverAppBar(
              backgroundColor: Theme.of(context).colorScheme.surface,
              pinned: true,
              floating: false,
              snap: false,
              automaticallyImplyLeading: false,
              leading: widget.leading,
              title: widget.titleBuilder(context),
              actions: widget.actionsBuilder(context),
              bottom: widget.bottom,
              shape: appBarBorder(context),
            ),
          ];
        },
        body: widget.bodyBuilder(context),
      ),
    );
  }
}

/// Builds the standard action-bar icons shared by group feeds: refresh, plus
/// whatever [extra] the caller wants next to it.
List<Widget> defaultGroupActions(
  BuildContext context, {
  VoidCallback? onRefresh,
  List<Widget> extra = const [],
}) {
  return [
    IconButton(
      icon: const Icon(Icons.refresh),
      onPressed:
          onRefresh ??
          () async => await context.read<FeedRefreshController>().refresh(),
    ),
    ...extra,
  ];
}
