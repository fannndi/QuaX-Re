import 'dart:io';

/// Writes [content] to a sibling temp file and renames it over [file].
///
/// A crash between the write and the rename leaves the previous file intact
/// instead of a truncated one. Each write uses its own temp name, so two
/// writers that overlap cannot share (and truncate) one `.tmp`; the last
/// completed rename wins with a whole file, never a mix of both.
///
/// Android's rename replaces the target atomically. Windows refuses an
/// existing target, so the delete-then-rename fallback is only for tests and
/// desktop tooling. On Android a rename failure is a real error: deleting the
/// only copy and retrying would lose the previous ledger instead of preserving
/// it.
int _writeSequence = 0;

Future<void> writeAtomically(File file, String content) async {
  final tmp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}-${_writeSequence++}.tmp');
  await tmp.writeAsString(content, flush: true);
  try {
    await tmp.rename(file.path);
  } on FileSystemException {
    if (!Platform.isWindows) {
      try {
        await tmp.delete();
      } catch (_) {}
      rethrow;
    }
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }
}
