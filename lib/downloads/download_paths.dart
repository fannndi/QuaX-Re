import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Temp-directory override for tests: path_provider has no plugin in the unit
/// test binary, so a transfer test needs a real directory it can inspect.
@visibleForTesting
Directory? debugTempDirectoryOverride;

Future<Directory> downloadTempDirectory() async =>
    debugTempDirectoryOverride ?? await getTemporaryDirectory();

/// The resumable partial file of a queued transfer. The name is stable because
/// a later attempt resumes from these bytes with a Range request.
Future<String> partialPathFor(String fileName) async =>
    p.join((await downloadTempDirectory()).path, 'quax-download-$fileName');

/// The temp file of a one-shot share. It must never collide with a queued
/// transfer of the same media: both used to write `quax-download-<name>`.
Future<String> shareTempPathFor(String fileName) async => p.join(
    (await downloadTempDirectory()).path,
    'quax-share-${DateTime.now().microsecondsSinceEpoch}-$fileName');

Future<void> deletePartial(String fileName) async {
  try {
    final file = File(await partialPathFor(fileName));
    if (await file.exists()) await file.delete();
  } catch (_) {
    // Best-effort: a missing directory or a locked file is not an error here.
  }
}
