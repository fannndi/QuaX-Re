import 'package:material_ui/material_ui.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/likes/liked_tweet_model.dart';
import 'package:provider/provider.dart';

/// The small relationship tags on the right of a post: liked on X, liked
/// locally, or bookmarked on X. The two like states are independent because a
/// local like never leaves the phone.
///
/// The caller passes the tweet that is actually shown (the original of a
/// repost), so the badges describe the post under the reader's thumb.
class TweetStatusRail extends StatelessWidget {
  final TweetWithCard tweet;

  const TweetStatusRail({super.key, required this.tweet});

  @override
  Widget build(BuildContext context) {
    return Consumer<LikedTweetModel>(
      builder: (context, likedModel, _) {
        final id = tweet.idStr;
        final likedHere = id != null && likedModel.isLiked(id);
        final likedOnX = tweet.favorited == true;
        final saved = tweet.bookmarked == true;
        if (!likedOnX && !likedHere && !saved) {
          return const SizedBox.shrink();
        }

        final scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
          child: Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 6,
              runSpacing: 4,
              children: [
                if (likedOnX)
                  _StatusChip(
                    label: L10n.of(context).label_liked,
                    icon: Icons.favorite,
                    background: scheme.primaryContainer,
                    foreground: scheme.onPrimaryContainer,
                  ),
                if (likedHere)
                  _StatusChip(
                    label: L10n.of(context).label_liked_here,
                    icon: Icons.favorite,
                    background: scheme.surfaceContainerHighest,
                    foreground: scheme.onSurfaceVariant,
                  ),
                if (saved)
                  _StatusChip(
                    label: L10n.of(context).label_saved,
                    icon: Icons.bookmark,
                    background: scheme.secondaryContainer,
                    foreground: scheme.onSecondaryContainer,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color background;
  final Color foreground;

  const _StatusChip({
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: foreground),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
