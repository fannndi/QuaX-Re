import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:pref/pref.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/utils/downloads.dart';
import 'package:quax/utils/network_status.dart';

/// Brings failed downloads back to life on their own: while the queue holds
/// retryable failures, a light reachability probe runs every 15 seconds and,
/// once the network answers, the entries are queued again through the normal
/// one-at-a-time machinery (with a Range resume). Each attempt is auto-resumed at
/// most [_maxAutoResumes] times per app run, so a permanently broken server
/// falls back to the manual Retry instead of being hammered.
class ConnectivityWatcher with WidgetsBindingObserver {
  static final ConnectivityWatcher _instance = ConnectivityWatcher._();

  factory ConnectivityWatcher() => _instance;

  ConnectivityWatcher._();

  static const _probeInterval = Duration(seconds: 15);
  static const _maxAutoResumes = 3;

  final Map<String, int> _autoResumes = {};
  Timer? _timer;
  BasePrefService? _prefs;
  bool _probing = false;
  bool _observing = false;
  bool _foreground = true;

  @visibleForTesting
  static bool? debugForeground;
  @visibleForTesting
  static Future<bool> Function()? debugReachable;
  @visibleForTesting
  static void Function(DownloadQueueItem item, BasePrefService prefs)?
  debugResume;

  bool get isForeground => debugForeground ?? _foreground;

  void ensure(BasePrefService prefs) {
    _prefs = prefs;
    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    }
    if (DownloadsModel().state.any(_isCandidate)) {
      scheduleCheck();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      unawaited(DownloadsModel().flush());
    }
    if (_foreground && DownloadsModel().state.any(_isCandidate)) {
      scheduleCheck();
    }
  }

  /// Called whenever an entry leaves the running state: keeps the probe alive
  /// while candidates remain, and stops it when there are none.
  ///
  /// The probe waits for the first tick. It used to run immediately on every
  /// failure, which undid the worker's own backoff and turned one 503 into a
  /// dozen identical requests inside a minute.
  void scheduleCheck() {
    _timer ??= Timer.periodic(_probeInterval, (_) => _probe());
  }

  bool _isCandidate(DownloadQueueItem item) =>
      item.status == DownloadStatus.error &&
      isRetryableDownloadError(item.error) &&
      (_autoResumes[item.attemptId] ?? 0) < _maxAutoResumes;

  Future<void> _probe() async {
    // One probe at a time. scheduleCheck() is called on every non-running status
    // transition — several times per download — and each call used to spawn its
    // own unawaited probe. Overlapping probes are individually harmless (a
    // read-only DNS lookup), but each one walked the candidate list and called
    // resumeDownload for it, double-incrementing _autoResumes. With a budget of
    // three, a genuinely flaky network got about 1.5 real retries.
    if (_probing) return;
    _probing = true;
    try {
      final prefs = _prefs;
      if (prefs == null || !isForeground) return;

      final queue = DownloadsModel();
      // Forget counters for attempts that left the queue. A replacement row can
      // reuse the file name, but it must start with a fresh budget.
      final queuedAttemptIds = queue.state
          .map((item) => item.attemptId)
          .toSet();
      _autoResumes.removeWhere(
        (attemptId, _) => !queuedAttemptIds.contains(attemptId),
      );
      final candidates = queue.state.where(_isCandidate).toList();
      if (candidates.isEmpty) {
        _stop();
        return;
      }

      if (!await _reachable() || !isForeground) return;

      for (final item in candidates) {
        if (!isForeground || queue.itemForAttempt(item.attemptId) == null) {
          continue;
        }
        _autoResumes[item.attemptId] = (_autoResumes[item.attemptId] ?? 0) + 1;
        final resume =
            debugResume ??
            ((item, prefs) => resumeDownload(item, prefs: prefs));
        resume(item, prefs);
      }
    } finally {
      _probing = false;
    }
  }

  /// Shares the app's single reachability probe: a second lookup and timer here
  /// meant two DNS requests and two places to change the target.
  Future<bool> _reachable() async =>
      debugReachable?.call() ?? NetworkStatus().check(force: true);

  @visibleForTesting
  Future<void> debugProbeNow() => _probe();

  @visibleForTesting
  void resetForTests() {
    _stop();
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    _autoResumes.clear();
    _prefs = null;
    _probing = false;
    _foreground = true;
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }
}
