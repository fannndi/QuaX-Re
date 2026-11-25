import 'package:material_ui/material_ui.dart';
import 'package:quax/app/design_tokens.dart';

/// A small leading banner inside a tweet tile (reposted-by, replying-to,
/// pinned) built from an inline icon plus rich text spans. It starts on the
/// same 16dp gutter as the post text so the eye reads one left edge.
class TweetTileLeading extends StatelessWidget {
  final Function()? onTap;
  final IconData icon;
  final Iterable<InlineSpan> children;

  const TweetTileLeading({
    super.key,
    this.onTap,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          AppSpace.sm,
          AppSpace.lg,
          0,
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                  children: children.toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
