import 'package:flutter_triple/flutter_triple.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pref/pref.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/generated/l10n.dart';

/// The queue screen: every image/GIF/video download this session started,
/// with live percent/speed while running — the Hentoid-ish queue view. Landed
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ScopedBuilder<DownloadsModel, List<DownloadQueueItem>>.transition(
      store: _queue,
      onError: (_, e) => Center(child: Text(e.toString())),
      onLoading: (_) => const Center(child: CircularProgressIndicator()),
      onState: (_, queue) {
        final theme2 = theme;

        return Scaffold(
          appBar: AppBar(title: Text(L10n.of(context).downloads)),
          body: queue.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.download_for_offline_outlined, size: 48),
                      const SizedBox(height: 12),
                      Text(L10n.of(context).downloads_empty, style: theme2.textTheme.bodyMedium),
                      const SizedBox(height: 8),
                      Text(
                        L10n.of(context).downloaded_in_library,
                        style: theme2.textTheme.bodySmall,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: queue.length,
                  itemBuilder: (context, index) {
                    final item = queue[index];
                    return ListTile(
                      leading: Icon(item.isVideo ? Icons.smart_display_outlined : Icons.image_outlined),
                      title: Text(item.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme2.textTheme.bodyMedium),
                      subtitle: item.done
                          ? null
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                item.totalMb == null
                                    ? const LinearProgressIndicator()
                                    : LinearProgressIndicator(
                                        value: (item.receivedMb / item.totalMb!).clamp(0.0, 1.0)),
                                Text('${item.receivedMb.toStringAsFixed(1)} MB'
                                    '${item.totalMb == null ? '' : ' / ${item.totalMb!.toStringAsFixed(1)} MB'}'
                                    ' · ${item.speedMbPerSec.toStringAsFixed(1)} MB/s'),
                              ],
                            ),
                      trailing: item.done ? const Icon(Icons.check_circle_outline, color: Colors.green) : null,
                    );
                  },
                ),
        );
      },
    );
  }
}
