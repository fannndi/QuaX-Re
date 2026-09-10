import 'package:flutter_triple/flutter_triple.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/utils/downloads.dart';

/// The queue screen: live downloads, failed ones to retry (resuming where
/// possible) and the recent history — persisted across app restarts. Landed
/// files are browsable in the Saved screen's Downloaded tab.
class DownloadsScreen extends StatefulWidget {
  final BasePrefService prefs;

  const DownloadsScreen({super.key, required this.prefs});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  late final DownloadsModel _queue = DownloadsModel();

  @override
  void initState() {
    super.initState();
    _queue.load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ScopedBuilder<DownloadsModel, List<DownloadQueueItem>>.transition(
      store: _queue,
      onError: (_, e) => Center(child: Text(e.toString())),
      onLoading: (_) => const Center(child: CircularProgressIndicator()),
      onState: (_, queue) {
        final hasFinished = queue.any((item) => item.status == DownloadStatus.done);
        return Scaffold(
          appBar: AppBar(
            title: Text(L10n.of(context).downloads),
            actions: [
              if (hasFinished)
                IconButton(
                  icon: const Icon(Icons.delete_sweep_outlined),
                  tooltip: L10n.of(context).delete,
                  onPressed: _queue.clearFinished,
                ),
            ],
          ),
          body: queue.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.download_for_offline_outlined, size: 48),
                      const SizedBox(height: 12),
                      Text(L10n.of(context).downloads_empty, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: queue.length,
                  itemBuilder: (context, index) => _buildTile(context, theme, queue[index]),
                ),
        );
      },
    );
  }

  Widget _buildTile(BuildContext context, ThemeData theme, DownloadQueueItem item) {
    switch (item.status) {
      case DownloadStatus.running:
        return ListTile(
          leading: Icon(item.isVideo ? Icons.smart_display_outlined : Icons.image_outlined),
          title: Text(item.fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              item.totalBytes == null
                  ? const LinearProgressIndicator()
                  : LinearProgressIndicator(
                      value: (item.receivedBytes / item.totalBytes!).clamp(0.0, 1.0)),
              Text('${item.receivedMb.toStringAsFixed(1)} MB'
                  '${item.totalMb == null ? '' : ' / ${item.totalMb!.toStringAsFixed(1)} MB'}'
                  '\u00b7 ${item.speedMbPerSec.toStringAsFixed(1)} MB/s'),
            ],
          ),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            tooltip: L10n.of(context).cancel,
            onPressed: () => _queue.cancel(item.fileName),
          ),
        );
      case DownloadStatus.error:
        return ListTile(
          leading: Icon(item.isVideo ? Icons.smart_display_outlined : Icons.image_outlined),
          title: Text(item.fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
          subtitle: Text(
            item.error == 'interrupted'
                ? L10n.of(context).download_interrupted
                : (item.error ?? L10n.of(context).download_failed),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: L10n.of(context).retry,
                onPressed: () => retryDownload(context, item, prefs: widget.prefs),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: L10n.of(context).delete,
                onPressed: () => _queue.remove(item.fileName),
              ),
            ],
          ),
        );
      case DownloadStatus.done:
        return ListTile(
          leading: Icon(item.isVideo ? Icons.smart_display_outlined : Icons.image_outlined),
          title: Text(item.fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
          subtitle: Text(L10n.of(context).successfully_saved_the_media),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_outline, color: Colors.green),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: L10n.of(context).delete,
                onPressed: () => _queue.remove(item.fileName),
              ),
            ],
          ),
        );
    }
  }
}
