import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:quax/constants.dart';
import 'package:quax/home/_following.dart';
import 'package:quax/home/_for_you.dart';
import 'package:quax/tweet/paginated_tweet_list.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/group/_feed_shell.dart';
import 'package:quax/group/group_model.dart';
import 'package:quax/search/search.dart';

typedef FeedTabTitleBuilder = String Function(BuildContext context);

enum FeedTab { foryou, following }

class FeedTabOption {
  final FeedTab id;
  final FeedTabTitleBuilder titleBuilder;

  FeedTabOption(this.id, this.titleBuilder);
}

final List<FeedTabOption> feedTabs = [
  FeedTabOption(FeedTab.foryou, (c) => L10n.of(c).foryou),
  FeedTabOption(FeedTab.following, (c) => L10n.of(c).following),
];

FeedTab feedTabFromId(String? id) =>
    FeedTab.values.firstWhere((e) => e.name == id, orElse: () => FeedTab.foryou);

class FeedScreen extends StatefulWidget {
  final ScrollController scrollController;
  final String id;

  const FeedScreen({super.key, required this.scrollController, required this.id});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> with SingleTickerProviderStateMixin {
  final TweetFeedController _followingFeed = TweetFeedController();
  final TweetFeedController _foryouFeed = TweetFeedController();
  TabController? _tabController;

  @override
  void dispose() {
    _tabController?.dispose();
    _followingFeed.dispose();
    _foryouFeed.dispose();
    super.dispose();
  }

  TabController _createTabController(BasePrefService prefs) {
    final stored = feedTabFromId(prefs.get<String>(optionHomeDefaultFeedTab));
    final initialIndex = feedTabs.indexWhere((e) => e.id == stored).clamp(0, feedTabs.length - 1);
    final controller = TabController(length: feedTabs.length, vsync: this, initialIndex: initialIndex);
    controller.addListener(() {
      if (!controller.indexIsChanging) {
        prefs.set<String>(optionHomeDefaultFeedTab, feedTabs[controller.index].id.name);
      }
    });
    return controller;
  }

  @override
  Widget build(BuildContext context) {
    final BasePrefService prefs = PrefService.of(context);
    final tabController = _tabController ??= _createTabController(prefs);

    return GroupFeedShell(
      scrollController: widget.scrollController,
      groupId: widget.id,
      automaticallyImplyLeading: false,
      titleBuilder: (context) => TabBar(
        controller: tabController,
        tabs: feedTabs.map((e) => Tab(text: e.titleBuilder(context))).toList(),
        onTap: (index) {
          // Tapping the already-active tab refreshes that feed (X-style).
          if (index != tabController.index || tabController.indexIsChanging) return;
          (index == 0 ? _foryouFeed : _followingFeed).softRefresh();
        },
      ),
      actionsBuilder: (context) {
        final model = context.read<GroupModel>();
        // Home feeds are read-only: search replaces the drawer hamburger, the
        // drawer (settings) stays reachable by edge swipe.
        return defaultGroupActions(
          context,
          model: model,
          showMore: false,
          showSettings: false,
          extra: [
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: () => Navigator.pushNamed(
                context,
                routeSearch,
                arguments: SearchArguments(0, focusInputOnOpen: true),
              ),
            ),
          ],
        );
      },
      bodyBuilder: (context) {
        return TabBarView(
          controller: tabController,
          children: [
            ForYouTweets(_foryouFeed),
            FollowingTweets(_followingFeed),
          ],
        );
      },
    );
  }
}
