import 'package:flutter_triple/flutter_triple.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/library/library_screen.dart';
import 'package:quax/utils/downloads.dart';

/// The Download tab: the queue on one side, the hidden library (the gallery
/// where finished clips play) on the other — toggled like the home feed.
class DownloadsTab extends StatefulWidget {
  final BasePrefService prefs;
  final ScrollController scrollController;

  const DownloadsTab({super.key, required this.prefs, required this.scrollController});

  @override
  State<DownloadsTab> createState() => _DownloadsTabState();
}

class _DownloadsTabState extends State<DownloadsTab> with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(length: 2, vsync: this);
  late final DownloadsModel _queue = DownloadsModel();

  @override
  void initState() {
    super.initState();
    _queue.load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScopedBuilder<DownloadsModel, List<DownloadQueueItem>>.transition(
      store: _queue,
      onError: (_, e) => Center(child: Text(e.toString())),
      onLoading: (_) => const Center(child: CircularProgressIndicator()),
      onState: (_, queue) {
        final hasFinished = queue.any((item) => item.status == DownloadStatus.done);
        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: TabBar(
              controller: _tabController,
              tabs: [
                Tab(text: L10n.of(context).queue),
                Tab(text: L10n.of(context).gallery),
              ],
            ),
            actions: [
              if (hasFinished)
                IconButton(
                  icon: const Icon(Icons.delete_sweep_outlined),
                  tooltip: L10n.of(context).delete,
                  onPressed: _queue.clearFinished,
                ),
            ],
          ),
          body: TabBarView(
            controller: _tabController,
            children: [
              _QueueList(queue: queue, prefs: widget.prefs),
              LibraryScreen(prefs: widget.prefs),
            ],
          ),
        );
      },
    );
  }
}

class _QueueList extends StatelessWidget {
  final List<DownloadQueueItem> queue;
  final BasePrefService prefs;

  const _QueueList({required this.queue, required this.prefs});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (queue.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.download_for_offline_outlined, size: 48),
            const SizedBox(height: 12),
            Text(L10n.of(context).downloads_empty, style: theme.textTheme.bodyMedium),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: queue.length,
      itemBuilder: (context, index) => switch (queue[index].status) {
        DownloadStatus.running => _RunningCard(item: queue[index]),
        DownloadStatus.error => _ErrorCard(item: queue[index], prefs: prefs),
        DownloadStatus.done => _DoneCard(item: queue[index]),
      },
    );
  }
}

class _TypeAvatar extends StatelessWidget {
  final DownloadQueueItem item;
  final Color? color;

  const _TypeAvatar({required this.item, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: (color ?? theme.colorScheme.primary).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        item.isVideo ? Icons.smart_display_outlined : Icons.image_outlined,
        color: color ?? theme.colorScheme.primary,
      ),
    );
  }
}

class _RunningCard extends StatelessWidget {
  final DownloadQueueItem item;

  const _RunningCard({required this.item});

  String get _details {
    final parts = <String>[];
    if (item.totalBytes != null && item.totalBytes! > 0) {
      parts.add('${(item.receivedBytes / item.totalBytes! * 100).clamp(0, 100).toStringAsFixed(0)}%');
    }
    parts.add(item.totalMb == null
        ? '${item.receivedMb.toStringAsFixed(1)} MB'
        : '${item.receivedMb.toStringAsFixed(1)} / ${item.totalMb!.toStringAsFixed(1)} MB');
    if (item.speedMbPerSec > 0.05) {
      parts.add('${item.speedMbPerSec.toStringAsFixed(1)} MB/s');
    }
    return parts.join(' \u00b7 ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction =
        item.totalBytes == null || item.totalBytes == 0 ? null : (item.receivedBytes / item.totalBytes!).clamp(0.0, 1.0);

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          children: [
            _TypeAvatar(item: item),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: fraction, minHeight: 6),
                  ),
                  const SizedBox(height: 6),
                  Text(_details, style: theme.textTheme.labelSmall),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: L10n.of(context).cancel,
              onPressed: () => DownloadsModel().cancel(item.fileName),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final DownloadQueueItem item;
  final BasePrefService prefs;

  const _ErrorCard({required this.item, required this.prefs});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = item.error == 'interrupted'
        ? L10n.of(context).download_interrupted
        : (item.error ?? L10n.of(context).download_failed);

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          children: [
            _TypeAvatar(item: item, color: theme.colorScheme.error),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error)),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: L10n.of(context).retry,
              onPressed: () => retryDownload(context, item, prefs: prefs),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: L10n.of(context).delete,
              onPressed: () => DownloadsModel().remove(item.fileName),
            ),
          ],
        ),
      ),
    );
  }
}

class _DoneCard extends StatelessWidget {
  final DownloadQueueItem item;

  const _DoneCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, color: Colors.green.shade400, size: 32),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(L10n.of(context).successfully_saved_the_media, style: theme.textTheme.labelSmall),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: L10n.of(context).delete,
              onPressed: () => DownloadsModel().remove(item.fileName),
            ),
          ],
        ),
      ),
    );
  }
}
