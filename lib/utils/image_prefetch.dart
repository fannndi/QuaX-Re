import 'package:extended_image/extended_image.dart';
import 'package:flutter/widgets.dart';
import 'package:pref/pref.dart';
import 'package:quax/client/client.dart';
import 'package:quax/constants.dart';
import 'package:quax/utils/downloads.dart';
import 'package:quax/utils/network_status.dart';

/// Warms the image cache for a freshly loaded page: the pictures the reader is
/// about to scroll to are fetched quietly, so they appear without a spinner
/// (and stay readable offline afterwards). Videos are skipped — the auto-cache
/// takes care of clips.
///
/// Skipped while offline, on metered connections, and when media autoload is
/// off, so it never spends data behind the reader's back.
Future<void> prefetchChainImages(BuildContext context, List<TweetChain> chains,
    {int limit = 8}) async {
  final prefs = PrefService.of(context, listen: false);
  if (prefs.get<bool>(optionMediaDisableAutoload) ?? false) return;
  if (!NetworkStatus().online.value) return;
  if (await isMeteredConnection() == true) return;

  final urls = <String>[];
  outer:
  for (final chain in chains) {
    for (final tweet in chain.tweets) {
      final media = tweet.extendedEntities?.media;
      if (media == null) continue;

      for (final item in media) {
        if (item.videoInfo != null) continue;
        final url = item.mediaUrlHttps;
        if (url == null) continue;

        urls.add(url);
        if (urls.length >= limit) break outer;
      }
    }
  }

  for (final url in urls) {
    if (!context.mounted) return;
    try {
      await precacheImage(ExtendedNetworkImageProvider(url), context);
    } catch (_) {
      // A failed prefetch only means the normal lazy load does the work.
    }
  }
}
