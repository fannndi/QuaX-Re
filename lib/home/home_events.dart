import 'package:flutter/foundation.dart';

/// Bumped whenever the Home tab is (re)selected in the bottom navigation, so
/// the feed can quietly refresh after an absence without a manual pull.
final ValueNotifier<int> homeFeedSelected = ValueNotifier<int>(0);
