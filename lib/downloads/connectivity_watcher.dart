import 'dart:async';
import 'dart:io';

import 'package:pref/pref.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/utils/downloads.dart';

/// Brings failed downloads back to life on their own: while the queue holds
/// retryable failures, a light reachability probe runs every 15 seconds and,
/// once the network answers, the entries are queued again through the normal
/// one-at-a-time machinery (with a Range resume). Each file is auto-resumed at
/// most [_maxAutoResumes] times per app run, so a permanently broken server
/// falls back to the manual Retry instead of being hammered.
class ConnectivityWatcher {
  static final ConnectivityWatcher _instance = ConnectivityWatcher._();

  factory ConnectivityWatcher() => _instance;

  ConnectivityWatcher._();

  static const _probeInterval = Duration(seconds: 15);
  static const _maxAutoResumes = 3;

  final Map<String, int> _autoResumes = {};
  Timer? _timer;
  BasePrefService? _prefs;

  /// Called at startup: remembers the preferences and starts probing when the
  /// persisted history already holds retryable failures.
  void ensure(BasePrefService prefs) {
    _prefs = prefs;
    if (DownloadsModel().state.any(_isCandidate)) {
      scheduleCheck();
    }
  }

  /// Called whenever an entry leaves the running state: keeps the probe alive
  /// while candidates remain, and stops it when there are none.
  void scheduleCheck() {
    _timer ??= Timer.periodic(_probeInterval, (_) => _probe());
    unawaited(_probe());
  }

  bool _isCandidate(DownloadQueueItem item) =>
      item.status == DownloadStatus.error &&
      isRetryableDownloadError(item.error) &&
      (_autoResumes[item.fileName] ?? 0) < _maxAutoResumes;

  Future<void> _probe() async {
    final prefs = _prefs;
    if (prefs == null) return;

    final queue = DownloadsModel();
    final candidates = queue.state.where(_isCandidate).toList();
    if (candidates.isEmpty) {
      _stop();
      return;
    }

    if (!await _reachable()) return;

    for (final item in candidates) {
      if (!queue.contains(item.fileName)) continue;
      _autoResumes[item.fileName] = (_autoResumes[item.fileName] ?? 0) + 1;
      resumeDownload(item, prefs: prefs);
    }
  }

  Future<bool> _reachable() async {
    try {
      final addresses = await InternetAddress.lookup('x.com').timeout(const Duration(seconds: 5));
      return addresses.isNotEmpty && addresses.first.rawAddress.isNotEmpty;
    } on Exception {
      return false;
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }
}
