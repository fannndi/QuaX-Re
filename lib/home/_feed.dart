import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:quax/client/active_account_button.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/constants.dart';
import 'package:quax/home/_following.dart';
import 'package:quax/home/_for_you.dart';
import 'package:quax/home/home_events.dart';
import 'package:quax/tweet/paginated_tweet_list.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/group/_feed_shell.dart';
import 'package:quax/group/group_model.dart';
import 'package:quax/search/search.dart';
import 'package:quax/ui/errors.dart';

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
  final TweetFeedController _followingFeed = TweetFeedController(mergeOnRefresh: true);
  final TweetFeedController _foryouFeed = TweetFeedController();
  TabController? _tabController;

  @override
  void initState() {
    super.initState();
    // Switching the active account speaks for a different timeline: drop both
    // feeds instead of merging the new first page on top of the previous
    // login's posts.
    accountsRevision.addListener(_onAccountsChanged);
    // Coming back to the Home tab after a while refreshes the active feed once,
    // keeping the return just as fresh as a resume.
    homeFeedSelected.addListener(_onHomeSelected);
  }

  DateTime _lastAutoRefreshAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _onHomeSelected() {
    if (DateTime.now().difference(_lastAutoRefreshAt) < const Duration(minutes: 1)) return;
    _lastAutoRefreshAt = DateTime.now();

    final controller = _tabController;
    if (controller == null) return;
    final feed = controller.index == 0 ? _foryouFeed : _followingFeed;
    if (feed.hasItems) {
      feed.softRefresh();
    }
  }

  void _onAccountsChanged() {
    _foryouFeed.reset();
    _followingFeed.reset();

    if (!mounted) return;
    // Recreating the feed widgets drops their local state too: the held-back
    // "new posts" page, the scroll-restore flag and the scroll offset belong
    // to the account that is gone.
    setState(() {});

    final handle = activeAccount.value?.handle;
    if (handle != null) {
      showSnackBar(context, icon: '👤', message: L10n.of(context).account_switched(handle));
    }
  }

  @override
  void dispose() {
    accountsRevision.removeListener(_onAccountsChanged);
    homeFeedSelected.removeListener(_onHomeSelected);
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
        // Home feeds are read-only: every secondary door (notifications,
        // search, account, settings) lives in this app bar.
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
            // Account switching lives here, not in Settings.
            const ActiveAccountButton(),
            // Settings moved out of the navbar too: the gear is its only door.
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: L10n.of(context).settings,
              onPressed: () => Navigator.pushNamed(context, routeSettings),
            ),
          ],
        );
      },
      bodyBuilder: (context) {
        // Keyed by the account revision: on a switch the feed widgets (and
        // their scroll offset, pill and restore flags) are built fresh for the
        // new login instead of carrying the previous account's reading state.
        final revision = accountsRevision.value;
        final accountId = activeAccount.value?.id;
        return TabBarView(
          controller: tabController,
          children: [
            ForYouTweets(_foryouFeed, key: ValueKey('foryou.$revision'), accountId: accountId),
            FollowingTweets(_followingFeed, key: ValueKey('following.$revision'), accountId: accountId),
          ],
        );
      },
    );
  }
}
