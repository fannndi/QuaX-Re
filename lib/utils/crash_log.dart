import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The on-device record of the errors that ended the process.
///
/// Nothing leaves the phone: the file exists so a death that produced no
/// console can still be read from Settings. Entries are capped and rotated so
/// a crash loop cannot fill the disk, and every query string is stripped
/// because X's request URLs carry the reader's user id and search terms.
class CrashLog {
  static const int maxBytes = 256 * 1024;

  /// Entries recorded before the support directory was known (the binding and
  /// path_provider calls themselves can fail).
  static const int _pendingLimit = 20;

  static File? _file;
  static final List<String> _pending = [];

  static Future<void> init() async {
    if (_file != null) return;
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}${Platform.pathSeparator}crashes.log');
      final pending = List<String>.from(_pending);
      _pending.clear();
      for (final entry in pending) {
        _write(entry);
      }
    } catch (_) {
      // No directory, no file: the entries stay in memory for this run.
    }
  }

  /// Test hook. Passing null restores the "buffer in memory" behaviour.
  static void overrideFileForTest(File? file) {
    _file = file;
    _pending.clear();
  }

  static void record(Object error, StackTrace? stackTrace, {String kind = 'error'}) {
    final entry = StringBuffer()
      ..writeln('--- ${DateTime.now().toIso8601String()} [$kind]')
      ..writeln(_redact('$error'));
    if (stackTrace != null) {
      entry.writeln(_redact('$stackTrace'));
    }
    final text = entry.toString();
    if (_file == null) {
      _pending.add(text);
      if (_pending.length > _pendingLimit) _pending.removeAt(0);
      return;
    }
    _write(text);
  }

  /// Everything recorded so far, oldest first. A missing file reads as empty.
  static Future<String> read() async {
    final buffer = StringBuffer();
    final file = _file;
    if (file == null) return _pending.join();
    try {
      final backup = File('${file.path}.1');
      if (await backup.exists()) buffer.write(await backup.readAsString());
      if (await file.exists()) buffer.write(await file.readAsString());
    } catch (_) {
      // An unreadable log is reported as empty rather than breaking Settings.
    }
    return buffer.toString();
  }

  static Future<void> clear() async {
    _pending.clear();
    final file = _file;
    if (file == null) return;
    for (final path in [file.path, '${file.path}.1']) {
      try {
        final target = File(path);
        if (await target.exists()) await target.delete();
      } catch (_) {
        // Best effort: a log that cannot be deleted is not worth an error.
      }
    }
  }

  static void _write(String entry) {
    final file = _file;
    if (file == null) return;
    try {
      if (file.existsSync() && file.lengthSync() > maxBytes) {
        final backup = File('${file.path}.1');
        if (backup.existsSync()) backup.deleteSync();
        file.renameSync(backup.path);
      }
      file.writeAsStringSync(entry, mode: FileMode.append, flush: true);
    } catch (_) {
      // Recording a crash must never become a second crash.
    }
  }

  /// Drops `?query` from anything that looks like a URL, keeping host and
  /// path so the failing request is still identifiable.
  static String _redact(String value) => value.replaceAll(_queryString, '?<redacted>');

  static final RegExp _queryString = RegExp(r'''\?[^\s)\]"'<>]*''');
}
