import 'dart:io';

/// Writes [content] to a sibling temp file and renames it over [file].
///
/// A crash between the write and the rename leaves the previous file intact
/// instead of a truncated one. Android's rename replaces the target atomically;
/// Windows refuses an existing target, so the delete-then-rename fallback is
/// only for tests and desktop tooling.
Future<void> writeAtomically(File file, String content) async {
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(content, flush: true);
  try {
    await tmp.rename(file.path);
  } on FileSystemException {
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }
}
