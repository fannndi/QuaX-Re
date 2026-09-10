import 'package:flutter_triple/flutter_triple.dart';
import 'package:quax/downloads/download_notifications.dart';

/// One entry of the download queue. [done] flips once the file reached its
/// destination; it is then browsable in the Saved screen's Downloaded tab.
/// A cancelled download removes itself from the queue.
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

/// Hentoid-style queue: one process-wide store fed by the streamed downloads.
/// The queue screen shows live percent/speed while the reader stays usable.
class DownloadsModel extends Store<List<DownloadQueueItem>> {
  static final DownloadsModel _instance = DownloadsModel._();

  factory DownloadsModel() => _instance;

  DownloadsModel._() : super([]);

  // Each running download leaves its abort hook here; the queue screen is able
  // to pull it without owning the HTTP machinery.
  final Map<String, void Function()> _cancelHooks = {};
  final Set<String> _cancelled = {};
  // Hooks fired when a download lands at its destination: the Downloaded tab
  // re-scans the library folder through these.
  final Map<String, void Function()> _doneListeners = {};

  void addDoneListener(String key, void Function() listener) => _doneListeners[key] = listener;

  void removeDoneListener(String key) => _doneListeners.remove(key);

  void register(String fileName, String url, bool isVideo) {
    _cancelled.remove(fileName);
    final existing = List.of(state);
    existing.removeWhere((item) => item.fileName == fileName);
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

  void attachCancel(String fileName, void Function() abort) => _cancelHooks[fileName] = abort;

  void progress(String fileName, double receivedMb, double? totalMb, double speedMbPerSec) {
    if (_cancelled.contains(fileName)) return;
    final updated = [
      for (final item in state)
        item.fileName == fileName
            ? item.copyWith(receivedMb: receivedMb, totalMb: totalMb, speedMbPerSec: speedMbPerSec)
            : item
    ];
    update(updated, force: true);
    DownloadNotifications.update(updated.firstWhere((e) => e.fileName == fileName));
  }

  void markDone(String fileName) {
    _cancelHooks.remove(fileName);
    final updated = [for (final item in state) item.fileName == fileName ? item.copyWith(done: true) : item];
    update(updated, force: true);
    DownloadNotifications.finalize(updated.firstWhere((e) => e.fileName == fileName));
    for (final listener in List.of(_doneListeners.values)) {
      try {
        listener();
      } catch (_) {}
    }
  }

  /// User-initiated abort from the queue screen. Returns whether a running
  /// download accepted it (drop the entry either way).
  bool cancel(String fileName) {
    _cancelled.add(fileName);
    _cancelHooks.remove(fileName)?.call();
    _cancelHooks.remove(fileName);
    final updated = state.where((item) => item.fileName != fileName).toList();
    update(updated, force: true);
    if (updated.isEmpty) {
      DownloadNotifications.clear();
    }
    return true;
  }

  void fail(String fileName) {
    _cancelHooks.remove(fileName);
    final updated = state.where((item) => item.fileName != fileName).toList();
    update(updated, force: true);
    if (updated.isEmpty) {
      DownloadNotifications.clear();
    }
  }
}
