import 'package:material_ui/material_ui.dart';
import 'package:quax/app/design_tokens.dart';
import 'package:quax/client/client.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/likes/liked_tweet_model.dart';
import 'package:provider/provider.dart';

/// The small relationship tags on the right of a post: liked on X, liked
/// locally, or bookmarked on X. Monochrome by design — the label says what the
/// state is, and only the icon carries the stronger contrast.
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
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.xs,
            AppSpace.lg,
            AppSpace.xxs,
          ),
          child: Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xs,
              children: [
                if (likedOnX)
                  _StatusChip(
                    label: L10n.of(context).label_liked,
                    icon: Icons.favorite,
                    foreground: scheme.onSurface,
                  ),
                if (likedHere)
                  _StatusChip(
                    label: L10n.of(context).label_liked_here,
                    icon: Icons.favorite,
                    foreground: scheme.onSurfaceVariant,
                  ),
                if (saved)
                  _StatusChip(
                    label: L10n.of(context).label_saved,
                    icon: Icons.bookmark,
                    foreground: scheme.onSurface,
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
  final Color foreground;

  const _StatusChip({
    required this.label,
    required this.icon,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: AppRadius.smAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: foreground),
          const SizedBox(width: AppSpace.xs),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}
