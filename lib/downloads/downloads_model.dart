import 'package:flutter_triple/flutter_triple.dart';

/// One entry of the download queue. [done] flips once the file reached its
/// destination; it is then browsable in the Saved screen's Downloaded tab.
class DownloadQueueItem {
  final String fileName;
  final String url;
  final bool isVideo;
  final double receivedMb;
  final double? totalMb;
  final double speedMbPerSec;
  final bool done;

  const DownloadQueueItem({
    required this.fileName,
    required this.url,
    required this.isVideo,
    required this.receivedMb,
    this.totalMb,
    required this.speedMbPerSec,
    this.done = false,
  });

  DownloadQueueItem copyWith({double? receivedMb, double? totalMb, double? speedMbPerSec, bool? done}) =>
      DownloadQueueItem(
        fileName: fileName,
        url: url,
        isVideo: isVideo,
        receivedMb: receivedMb ?? this.receivedMb,
        totalMb: totalMb ?? this.totalMb,
        speedMbPerSec: speedMbPerSec ?? this.speedMbPerSec,
        done: done ?? this.done,
      );
}

/// Hentoid-style queue: one process-wide store fed by the streamed downloads,
/// so the queue screen shows live percent/speed without touching the disk.
class DownloadsModel extends Store<List<DownloadQueueItem>> {
  static final DownloadsModel _instance = DownloadsModel._();

  factory DownloadsModel() => _instance;

  DownloadsModel._() : super([]);

  void register(String fileName, String url, bool isVideo) {
    final existing = List.of(state);
    if (existing.any((item) => item.fileName == fileName)) return;
    existing.insert(
        0,
        DownloadQueueItem(
            fileName: fileName,
            url: url,
            isVideo: isVideo,
            receivedMb: 0,
            totalMb: null,
            speedMbPerSec: 0,
            done: false));
    update(existing, force: true);
  }

  void progress(String fileName, double receivedMb, double? totalMb, double speedMbPerSec) {
    final updated = [
      for (final item in state)
        item.fileName == fileName
            ? item.copyWith(receivedMb: receivedMb, totalMb: totalMb, speedMbPerSec: speedMbPerSec)
            : item
    ];
    update(updated, force: true);
  }

  void markDone(String fileName) {
    final updated = [for (final item in state) item.fileName == fileName ? item.copyWith(done: true) : item];
    update(updated, force: true);
  }
}
