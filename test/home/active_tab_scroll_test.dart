import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:quax/constants.dart';
import 'package:quax/group/feed_refresh_controller.dart';
import 'package:quax/home/home_screen.dart';

void main() {
  testWidgets('Should scroll the feed body when the active tab is tapped again', (tester) async {
    var scrolled = 0;
    // NavigationBar asserts on at least two destinations, so the feed page is
    // index 1 and a second (non-feed) page sits beside it.
    final pages = [
      NavigationPage('downloads', (_) => 'Downloads', const Icon(Icons.download_outlined),
          const Icon(Icons.download)),
      NavigationPage('feed', (_) => 'Feed', const Icon(Icons.home_outlined), const Icon(Icons.home)),
    ];

    await tester.pumpWidget(MaterialApp(
      home: ScaffoldWithBottomNavigation(
        pages: pages,
        prefs: PrefServiceCache(cache: {optionShowNavigationLabels: false}),
        initialPage: 1,
        builder: (_) => [
          const SizedBox.shrink(),
          Builder(builder: (context) {
            FeedRefreshController? controller;
            try {
              controller = context.read<FeedRefreshController>();
            } on ProviderNotFoundException {
              controller = null;
            }
            controller?.register('feed', refresh: () async {}, scrollToTop: () => scrolled++);
            controller?.activeFeedId = 'feed';
            return const SizedBox.shrink();
          }),
        ],
      ),
    ));

    await tester.tap(find.byIcon(Icons.home));
    await tester.pumpAndSettle();

    expect(scrolled, 1,
        reason: 'Tapping the active tab must reach the controller the feed body registered its '
            'scroll-to-top on. Reading it from a context above the provider throws, and the tap '
            'either crashes or silently does nothing');
  });
}
