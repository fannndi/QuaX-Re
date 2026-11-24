import 'package:dart_twitter_api/twitter_api.dart';
import 'package:extended_image/extended_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/profile/media_grid/media_grid.dart';
import 'package:quax/profile/media_grid/media_grid_items/media_grid_item.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/tweet/_video.dart';
import 'package:quax/utils/paging.dart';

Media photo() => Media()
  ..idStr = 'photo-1'
  ..type = 'photo'
  ..mediaUrlHttps = 'https://pbs.twimg.com/media/photo.jpg';

Media gif() => Media()
  ..idStr = 'gif-1'
  ..type = 'animated_gif'
  ..mediaUrlHttps = 'https://pbs.twimg.com/media/thumb.jpg'
  ..videoInfo = (VideoInfo()..aspectRatio = [1, 1]);

void main() {
  testWidgets(
    'Should not build thumbnails or autoplay before a sensitive grid tile is revealed',
    (tester) async {
      final paging = CursorPagingController<String, MediaGridItem>(
        (_) async => (items: const <MediaGridItem>[], nextCursor: null),
      );
      addTearDown(paging.dispose);
      paging.replaceFirstPage([
        PhotoGridItem(
          tweetId: 'tweet-1',
          username: 'author',
          thumbnailUrl: 'https://pbs.twimg.com/media/photo.jpg',
          aspectRatio: 1,
          mediaIndex: 0,
          media: photo(),
          possiblySensitive: true,
        ),
        GifGridItem(
          tweetId: 'tweet-2',
          username: 'author',
          thumbnailUrl: 'https://pbs.twimg.com/media/thumb.jpg',
          aspectRatio: 1,
          mediaIndex: 0,
          media: gif(),
          possiblySensitive: true,
        ),
      ], null);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            L10n.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: L10n.delegate.supportedLocales,
          home: PrefService(
            service: PrefServiceCache(
              cache: {optionMediaDisableAutoload: true},
            ),
            child: ChangeNotifierProvider.value(
              value: TweetContextState(true),
              child: Scaffold(
                body: MediaGrid(
                  controller: paging.pagingController,
                  firstPageErrorPrefix: '',
                  newPageErrorPrefix: '',
                  emptyMessage: '',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.text(L10n.current.possibly_sensitive),
        findsNWidgets(2),
        reason: 'Each sensitive tweet needs its own warning in profile and search grids',
      );
      expect(
        find.byType(ExtendedImage),
        findsNothing,
        reason: 'A warning must gate the thumbnail itself, not merely cover it after loading',
      );
      expect(
        find.byType(TweetVideo),
        findsNothing,
        reason: 'A hidden GIF must not acquire a player or autoplay in the cache extent',
      );

      await tester.tap(find.byIcon(Icons.visibility_off_outlined).first);
      await tester.pump();

      expect(
        find.text(L10n.current.possibly_sensitive),
        findsOneWidget,
        reason:
            'Revealing one tile must leave the other tweet warning in place',
      );
      expect(
        find.byType(ExtendedImage),
        findsNothing,
        reason: 'Manual media loading still applies after the sensitive warning is dismissed',
      );
      expect(
        find.byType(TweetVideo),
        findsNothing,
        reason: 'Dismissing the warning must not bypass the separate autoplay/manual-load gate',
      );
    },
  );
}
