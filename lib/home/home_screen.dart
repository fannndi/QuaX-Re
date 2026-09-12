import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';
import 'package:quax/downloads/downloads_badge.dart';
import 'package:quax/downloads/downloads_screen.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/home/_feed.dart';
import 'package:quax/home/home_events.dart';
import 'package:quax/likes/likes_screen.dart';

typedef NavigationTitleBuilder = String Function(BuildContext context);

class NavigationPage {
  final String id;
  final NavigationTitleBuilder titleBuilder;
  final Widget icon;
  final Widget selectedIcon;

  NavigationPage(this.id, this.titleBuilder, this.icon, this.selectedIcon);
}

/// The fork's whole navigation: Download, Home (For You / Following) and Like,
/// with Home centered like a home button. Settings and search live in the
/// screen app bars — the app stays three tabs wide.
final List<NavigationPage> defaultHomePages = [
  NavigationPage('downloads', (c) => L10n.of(c).downloads,
      const DownloadsNavBadge(child: Icon(Icons.download_outlined)),
      const DownloadsNavBadge(child: Icon(Icons.download))),
  NavigationPage('feed', (c) => L10n.of(c).home, const Icon(Icons.home_outlined), const Icon(Icons.home)),
  NavigationPage('likes', (c) => L10n.of(c).likes,
      const Icon(Icons.favorite_border_outlined), const Icon(Icons.favorite)),
];

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _HomeScreen(prefs: PrefService.of(context));
  }
}

class _HomeScreen extends StatefulWidget {
  final BasePrefService prefs;

  const _HomeScreen({required this.prefs});

  @override
  State<_HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<_HomeScreen> {
  late final int _initialPage = _resolveInitialPage();

  int _resolveInitialPage() {
    final stored = widget.prefs.get<String>(optionHomeInitialTab);
    final index = defaultHomePages.indexWhere((page) => page.id == stored);
    if (index >= 0) return index;
    return defaultHomePages.indexWhere((page) => page.id == 'feed');
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldWithBottomNavigation(
      pages: defaultHomePages,
      prefs: widget.prefs,
      initialPage: _initialPage,
      builder: (scrollControllers) {
        return List.generate(defaultHomePages.length, (index) {
          switch (defaultHomePages[index].id) {
            case 'feed':
              return FeedScreen(
                scrollController: scrollControllers[index]!,
                id: '-1',
              );
            case 'downloads':
              return DownloadsTab(prefs: widget.prefs, scrollController: scrollControllers[index]!);
            case 'likes':
              return LikesScreen(scrollController: scrollControllers[index]!);
            default:
              return const SizedBox.shrink();
          }
        });
      },
    );
  }
}

class ScaffoldWithBottomNavigation extends StatefulWidget {
  final List<NavigationPage> pages;
  final BasePrefService prefs;
  final int initialPage;
  final List<Widget> Function(Map<int, ScrollController> scrollControllers) builder;

  const ScaffoldWithBottomNavigation(
      {super.key, required this.pages, required this.prefs, required this.initialPage, required this.builder});

  @override
  State<ScaffoldWithBottomNavigation> createState() => _ScaffoldWithBottomNavigationState();
}

class _ScaffoldWithBottomNavigationState extends State<ScaffoldWithBottomNavigation> {
  late PageController _pageController;
  late int _currentPage;
  final Map<int, ScrollController> _scrollControllers = {};

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
    _pageController = PageController(initialPage: widget.initialPage);
    for (int i = 0; i < widget.pages.length; i++) {
      _scrollControllers[i] = ScrollController();
    }
  }

  @override
  void didUpdateWidget(covariant ScaffoldWithBottomNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pages.length != oldWidget.pages.length) {
      // Dispose controllers that are no longer needed.
      _scrollControllers.keys.where((k) => k >= widget.pages.length).toList().forEach((k) {
        _scrollControllers[k]?.dispose();
        _scrollControllers.remove(k);
      });
      // Create controllers for new pages.
      for (int i = 0; i < widget.pages.length; i++) {
        if (!_scrollControllers.containsKey(i)) {
          _scrollControllers[i] = ScrollController();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _pageController,
        onPageChanged: (page) {
          setState(() {
            _currentPage = page;
          });
          if (defaultHomePages[page].id == 'feed') {
            homeFeedSelected.value++;
          }
        },
        children: widget.builder(_scrollControllers),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentPage,
        labelBehavior: widget.prefs.get(optionShowNavigationLabels)
            ? NavigationDestinationLabelBehavior.alwaysShow
            : NavigationDestinationLabelBehavior.alwaysHide,
        shadowColor: Colors.transparent,
        backgroundColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        height: 64,
        destinations: widget.pages.asMap().entries
            .map(
              (e) {
                final index = e.key;
                final page = e.value;
                final isSelected = _currentPage == index;
                final scale = widget.prefs.get(optionShowNavigationLabels) ? 1.0 : (isSelected ? 1.2 : 1.2);
                return NavigationDestination(
                  icon: AnimatedScale(
                    scale: scale,
                    duration: const Duration(milliseconds: 0),
                    curve: Curves.easeOut,
                    child: page.icon,
                  ),
                  selectedIcon: AnimatedScale(
                    scale: scale,
                    duration: const Duration(milliseconds: 0),
                    curve: Curves.easeOut,
                    child: page.selectedIcon,
                  ),
                  label: page.titleBuilder(context),
                );
              })
            .toList(),
        onDestinationSelected: (index) async {
          if (index == _currentPage) {
            final tappedId = widget.pages[index].id;
            if (tappedId == "feed" || tappedId.startsWith("group-")) {
              final scrollController = _scrollControllers[_currentPage];
              if (scrollController != null) {
                await scrollController.animateTo(0, duration: const Duration(seconds: 1), curve: Curves.easeInOut);
              }
            }
          }
          _pageController.jumpToPage(index);
        },
      ),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }
}
