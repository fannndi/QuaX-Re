import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Knows whether the phone has a working internet connection: a light DNS
/// probe (cached for a few seconds, so screens can ask freely) plus, while
/// offline, a periodic re-probe that flips [online] back by itself — which is
/// what offline mode uses to retry a feed the moment the connection returns.
class NetworkStatus {
  static final NetworkStatus _instance = NetworkStatus._();

  factory NetworkStatus() => _instance;

  NetworkStatus._();

  static const _probeInterval = Duration(seconds: 10);
  static const _cacheFor = Duration(seconds: 5);

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
      final addresses = await InternetAddress.lookup('x.com').timeout(const Duration(seconds: 5));
      reachable = addresses.isNotEmpty && addresses.first.rawAddress.isNotEmpty;
    } on Exception {
      reachable = false;
    }

    _lastCheckAt = DateTime.now();
    online.value = reachable;
    if (reachable) {
      _stopTimer();
    } else {
      _timer ??= Timer.periodic(_probeInterval, (_) => check(force: true));
    }
    return reachable;
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }
}
