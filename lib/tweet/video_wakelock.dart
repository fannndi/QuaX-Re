import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:wakelock_plus/wakelock_plus.dart';

class VideoWakelock {
  static final Set<Object> _holders = {};

  static void acquire(Object holder) {
    if (_holders.add(holder)) _apply();
  }

  static void release(Object holder) {
    if (_holders.remove(holder)) _apply();
  }

  static void reapply() => _apply();

  /// Test hook: drops every holder, so a test that throws mid-way cannot leak
  /// one into the next test. `flutter test` runs all files in one process.
  @visibleForTesting
  static void resetForTests() {
    _holders.clear();
  }

  static void _apply() => WakelockPlus.toggle(enable: _holders.isNotEmpty);
}
