import 'package:material_ui/material_ui.dart';

/// A quiet placeholder for a media grid: tiles arriving instead of a spinner.
class MediaGridSkeleton extends StatelessWidget {
  final int columns;
  final int rows;

  const MediaGridSkeleton({super.key, this.columns = 3, this.rows = 4});

  @override
  Widget build(BuildContext context) {
    final block = Theme.of(context).colorScheme.surfaceContainerHighest;

    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(2),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns < 1 ? 1 : columns,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: (columns < 1 ? 1 : columns) * rows,
      itemBuilder: (context, index) => ColoredBox(color: block),
    );
  }
}

/// A quiet placeholder for a list of posts: card-shaped blocks instead of a
/// lone spinner, so the wait reads as content arriving. Shared by the feed,
/// the Saved/liked lists and the profile tabs so a first load looks the same
/// everywhere.
class TweetListSkeleton extends StatelessWidget {
  final int items;

  const TweetListSkeleton({super.key, this.items = 5});

  @override
  Widget build(BuildContext context) {
    final block = Theme.of(context).colorScheme.surfaceContainerHighest;

    Widget bar(double widthFactor, double height) => FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: widthFactor,
          child: Container(
            height: height,
            decoration: BoxDecoration(color: block, borderRadius: BorderRadius.circular(6)),
          ),
        );

    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 8),
      itemCount: items,
      itemBuilder: (context, index) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(radius: 20, backgroundColor: block),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        bar(0.4, 12),
                        const SizedBox(height: 6),
                        bar(0.25, 10),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              bar(1.0, 12),
              const SizedBox(height: 6),
              bar(0.85, 12),
              const SizedBox(height: 14),
              Container(
                height: 140,
                width: double.infinity,
                decoration: BoxDecoration(color: block, borderRadius: BorderRadius.circular(12)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
