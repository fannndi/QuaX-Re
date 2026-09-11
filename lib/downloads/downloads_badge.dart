import 'package:flutter_triple/flutter_triple.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/downloads/downloads_model.dart';

/// The Download navbar icon with a Material 3 badge counting the transfers
/// that are running, waiting or paused.
class DownloadsNavBadge extends StatelessWidget {
  final Widget child;

  const DownloadsNavBadge({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ScopedBuilder<DownloadsModel, List<DownloadQueueItem>>.transition(
      store: DownloadsModel(),
      onError: (_, _) => child,
      onLoading: (_) => child,
      onState: (_, items) {
        final active = items
            .where((item) =>
                item.status == DownloadStatus.running ||
                item.status == DownloadStatus.queued ||
                item.status == DownloadStatus.paused)
            .length;

        return Badge.count(count: active, isLabelVisible: active > 0, child: child);
      },
    );
  }
}
