import 'package:dart_twitter_api/twitter_api.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:quax/constants.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/library/library_presence.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/tweet/_media.dart';
import 'package:quax/tweet/media_actions.dart';

Media video() => Media()
  ..idStr = 'clip-1'
  ..type = 'video'
  ..mediaUrlHttps = 'https://pbs.twimg.com/ext_tw_video_thumb/clip.jpg'
  ..videoInfo = (VideoInfo()
    ..durationMillis = 42000
    ..aspectRatio = [16, 9]
    ..variants = [
      (Variant()
        ..url = 'https://video.twimg.com/1080p.mp4'
        ..bitrate = 2176000
        ..contentType = 'video/mp4'),
    ]);

void main() {
  testWidgets(
    'Should put the duration below the media and follow library downloads',
    (tester) async {
      LibraryPresence.resetForTesting();
      addTearDown(LibraryPresence.resetForTesting);
      const root = '/library';
      final clip = video();
      final url = downloadableMediaUri(clip, tweetMedia: true).toString();
      // Warm the badge answer so the widget test stays synchronous: the
      // library integration itself is covered by library_model_test.
      expect(
        await LibraryPresence.contains(
          root: root,
          url: url,
          lookup: () async => '/library/clip.mp4',
        ),
        isTrue,
      );

      final context = TweetContextState(false);
      addTearDown(context.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            L10n.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: L10n.delegate.supportedLocales,
          home: PrefService(
            service: PrefServiceCache(
              cache: {
                optionLibraryPath: root,
                optionMediaDisableAutoload: true,
              },
            ),
            child: ChangeNotifierProvider<TweetContextState>.value(
              value: context,
              child: Scaffold(
                body: SingleChildScrollView(
                  child: TweetMedia(
                    sensitive: false,
                    media: [clip],
                    username: 'author',
                    tweetId: 'tweet-1',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final duration = find.text('0:42');
      expect(
        duration,
        findsOneWidget,
        reason: 'The total clip length must stay visible in the feed',
      );
      final mediaBox = tester.getRect(find.byType(PageView));
      expect(
        tester.getRect(duration).top,
        greaterThanOrEqualTo(mediaBox.bottom),
        reason:
            'The duration belongs under the video box, not over the picture',
      );
      expect(
        find.text(L10n.current.label_in_gallery),
        findsOneWidget,
        reason:
            'A file registered under this exact download URL must be marked as '
            'already in the gallery',
      );
    },
  );
}
