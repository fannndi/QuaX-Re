import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Knows whether the phone has working HTTPS connectivity. Name resolution
/// alone is not enough: captive portals and blocked TLS can resolve `x.com`
/// while no usable request can leave the device. Results are cached and
/// re-probed while offline.
class NetworkStatus {
  static final NetworkStatus _instance = NetworkStatus._();

  factory NetworkStatus() => _instance;

  NetworkStatus._({
    Future<bool> Function()? probe,
    this._cacheFor = const Duration(seconds: 5),
    this._probeInterval = const Duration(seconds: 10),
  }) : _probeInternet = probe ?? _defaultProbe;

  /// Deterministic seam for tests and alternative connectivity probes.
  @visibleForTesting
  NetworkStatus.withProbe(
    Future<bool> Function() probe, {
    Duration cacheFor = const Duration(seconds: 5),
    Duration probeInterval = const Duration(seconds: 10),
  }) : this._(probe: probe, cacheFor: cacheFor, probeInterval: probeInterval);

  final Future<bool> Function() _probeInternet;
  final Duration _cacheFor;
  final Duration _probeInterval;

  final ValueNotifier<bool> online = ValueNotifier<bool>(true);

  DateTime? _lastCheckAt;
  Future<bool>? _inflight;
  Timer? _timer;

  Future<bool> check({bool force = false}) async {
    final last = _lastCheckAt;
    if (!force && last != null && DateTime.now().difference(last) < _cacheFor) {
      return online.value;
    }
    return _inflight ??= _probe().whenComplete(() => _inflight = null);
  }

  Future<bool> _probe() async {
    var reachable = false;
    try {
      reachable = await _probeInternet();
    } on Object {
      reachable = false;
    }

    _lastCheckAt = DateTime.now();
    online.value = reachable;
    if (reachable) {
      _stopTimer();
    } else {
      _timer ??= Timer.periodic(
        _probeInterval,
        (_) => unawaited(check(force: true)),
      );
    }
    return reachable;
  }

  static Future<bool> _defaultProbe() async {
    try {
      final socket = await SecureSocket.connect(
        'x.com',
        443,
        timeout: const Duration(seconds: 5),
      );
      socket.destroy();
      return true;
    } on Object {
      // DNS success is only a diagnostic signal. A failed TLS handshake means
      // the app cannot reliably reach X, so it must remain offline.
      return false;
    }
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _stopTimer();
    online.dispose();
  }
}
