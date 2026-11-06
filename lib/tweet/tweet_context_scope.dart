import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:quax/constants.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/tweet/_video.dart';

/// Provides the [TweetContextState] and [VideoContextState] that tweet tiles
/// read from context. Any subtree rendering [TweetConversation]/[TweetTile] must
/// sit under this scope, otherwise those reads throw ProviderNotFoundException.
///
/// The states are created once and kept in sync with the preference keys: a
/// screen-scoped provider used to snapshot "hide sensitive" at creation, so
/// changing it in Settings only took effect on the next launch.
class TweetContextScope extends StatefulWidget {
  final Widget child;

  const TweetContextScope({super.key, required this.child});

  @override
  State<TweetContextScope> createState() => _TweetContextScopeState();
}

class _TweetContextScopeState extends State<TweetContextScope> {
  late final BasePrefService _prefs;
  late final TweetContextState _tweetContext;
  late final VideoContextState _videoContext;
  late final VoidCallback _onHideSensitiveChanged;
  late final VoidCallback _onMuteChanged;

  @override
  void initState() {
    super.initState();
    _prefs = PrefService.of(context, listen: false);
    _tweetContext = TweetContextState(_prefs.get<bool>(optionTweetsHideSensitive) ?? false);
    _videoContext = VideoContextState(_prefs.get<bool>(optionMediaDefaultMute) ?? false);

    _onHideSensitiveChanged = () {
      _tweetContext.setHideSensitive(_prefs.get<bool>(optionTweetsHideSensitive) ?? false);
    };
    _onMuteChanged = () {
      _videoContext.setMuted(_prefs.get<bool>(optionMediaDefaultMute) ?? false);
    };

    _prefs.addKeyListener(optionTweetsHideSensitive, _onHideSensitiveChanged);
    _prefs.addKeyListener(optionMediaDefaultMute, _onMuteChanged);
  }

  @override
  void dispose() {
    _prefs.removeKeyListener(optionTweetsHideSensitive, _onHideSensitiveChanged);
    _prefs.removeKeyListener(optionMediaDefaultMute, _onMuteChanged);
    _tweetContext.dispose();
    _videoContext.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<TweetContextState>.value(value: _tweetContext),
        ChangeNotifierProvider<VideoContextState>.value(value: _videoContext),
      ],
      child: widget.child,
    );
  }
}
