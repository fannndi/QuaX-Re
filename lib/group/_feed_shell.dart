import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:quax/group/feed_refresh_controller.dart';
import 'package:quax/group/group_model.dart';
import 'package:quax/subscriptions/users_model.dart';

class GroupFeedShell extends StatefulWidget {
  final ScrollController scrollController;
  final String groupId;
  final WidgetBuilder titleBuilder;
  final WidgetBuilder bodyBuilder;
  final List<Widget> Function(BuildContext) actionsBuilder;

  const GroupFeedShell({
    super.key,
    required this.scrollController,
    required this.groupId,
    required this.titleBuilder,
    required this.bodyBuilder,
    required this.actionsBuilder,
  });

  @override
  State<GroupFeedShell> createState() => _GroupFeedShellState();
}

class _GroupFeedShellState extends State<GroupFeedShell> with AutomaticKeepAliveClientMixin<GroupFeedShell> {
  final FeedRefreshController _feedRefreshController = FeedRefreshController();
  int _refreshCounter = 0;
  // Cached refs captured in didChangeDependencies — accessing the InheritedWidget
  // tree via context.read in dispose() triggers a framework warning, since
  // ancestors may already be unmounted by then.
  SubscriptionsModel? _subscriptionsModel;
  GroupsModel? _groupsModel;

  late final String _callbackKey = 'GroupFeedShell-${widget.groupId}-${identityHashCode(this)}';

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newSubs = context.read<SubscriptionsModel>();
    final newGroups = context.read<GroupsModel>();
    if (!identical(newSubs, _subscriptionsModel) || !identical(newGroups, _groupsModel)) {
      _subscriptionsModel?.removeReloadListener(_callbackKey);
      _groupsModel?.removeReloadListener(_callbackKey);
      _subscriptionsModel = newSubs;
      _groupsModel = newGroups;
      _subscriptionsModel!.addReloadListener(_callbackKey, _onReload);
      _groupsModel!.addReloadListener(_callbackKey, _onReload);
    }
  }

  // Triggered when subscriptions or group memberships change. Bumping the
  // counter remounts the body — for pushed-route feeds this drops the stale
  // (cached, just-invalidated) PagingController so the inner state re-fetches
  // a fresh one from the cache.
  void _onReload() {
    if (!mounted) return;
    setState(() {
      _refreshCounter++;
    });
  }

  @override
  void dispose() {
    _subscriptionsModel?.removeReloadListener(_callbackKey);
    _groupsModel?.removeReloadListener(_callbackKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Provider<FeedRefreshController>.value(
      value: _feedRefreshController,
      child: NestedScrollView(
        controller: widget.scrollController,
        floatHeaderSlivers: true,
        headerSliverBuilder: (context, innerBoxIsScrolled) {
          return [
            SliverAppBar(
              backgroundColor: Theme.of(context).colorScheme.surface,
              pinned: false,
              snap: true,
              floating: true,
              // The shell only exists inside the navigation PageView now, so it
              // never owns a back button — its drawer is reached by edge swipe.
              automaticallyImplyLeading: false,
              title: widget.titleBuilder(context),
              actions: widget.actionsBuilder(context),
            ),
          ];
        },
        body: KeyedSubtree(
          key: ValueKey(_refreshCounter),
          child: widget.bodyBuilder(context),
        ),
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
        onPressed: onRefresh ?? () async => await context.read<FeedRefreshController>().refresh()),
    ...extra,
  ];
}
