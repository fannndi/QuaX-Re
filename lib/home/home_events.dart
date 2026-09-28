import 'package:flutter/foundation.dart';

/// Bumped whenever the Home tab is (re)selected in the bottom navigation, so
/// the feed can quietly refresh after an absence without a manual pull.
final ValueNotifier<int> homeFeedSelected = ValueNotifier<int>(0);

/// Bumped when the reader asks for the archive (the Offline tab) from the
/// home's empty state: the navigation animates to that page.
final ValueNotifier<int> offlineTabRequest = ValueNotifier<int>(0);
