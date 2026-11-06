import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:quax/constants.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/tweet/_video.dart';
import 'package:quax/tweet/tweet_context_scope.dart';

void main() {
  setUp(VideoContextState.resetForTests);
  testWidgets('Should apply a hide-sensitive change without a restart', (tester) async {
    final prefs = PrefServiceCache(cache: {optionTweetsHideSensitive: false});

    await tester.pumpWidget(MaterialApp(
      home: PrefService(
        service: prefs,
        child: TweetContextScope(
          child: Consumer<TweetContextState>(
            builder: (context, model, child) => Text('hide=${model.hideSensitive}'),
          ),
        ),
      ),
    ));

    expect(find.text('hide=false'), findsOneWidget);

    await prefs.set<bool>(optionTweetsHideSensitive, true);
    await tester.pump();

    expect(find.text('hide=true'), findsOneWidget,
        reason: 'Settings is pushed over Home, so the already-mounted scope must react to the '
            'preference write instead of waiting for the next launch');
  });

  testWidgets('Should apply a mute change to the live video context', (tester) async {
    final prefs = PrefServiceCache(cache: {optionMediaDefaultMute: false});
    VideoContextState? video;

    await tester.pumpWidget(MaterialApp(
      home: PrefService(
        service: prefs,
        child: TweetContextScope(
          child: Consumer<VideoContextState>(
            builder: (context, model, child) {
              video = model;
              return Text('muted=${model.isMuted}');
            },
          ),
        ),
      ),
    ));

    expect(find.text('muted=false'), findsOneWidget);

    await prefs.set<bool>(optionMediaDefaultMute, true);
    await tester.pump();

    expect(find.text('muted=true'), findsOneWidget,
        reason: 'The mute switch used to be read once at scope creation');
    expect(video?.isMuted, isTrue);
  });
}
