import 'dart:io';

/// Writes [content] to a sibling temp file and renames it over [file].
///
/// A crash between the write and the rename leaves the previous file intact
/// instead of a truncated one. Each write uses its own temp name, so two
/// writers that overlap cannot share (and truncate) one `.tmp`; the last
/// completed rename wins with a whole file, never a mix of both.
///
/// Android's rename replaces the target atomically. Windows refuses an
/// existing target, so the move-aside fallback is only for tests and desktop
/// tooling. On Android a rename failure is a real error: moving the only copy
/// out of the way would risk losing the previous ledger.
int _writeSequence = 0;

String _tempPath(File file) =>
    '${file.path}.${DateTime.now().microsecondsSinceEpoch}-${_writeSequence++}.tmp';

/// Completes the write but leaves the sibling temp file for the caller to
/// commit. Vault rotation uses this to stage every envelope before replacing
/// any primary file.
Future<File> stageAtomically(File file, String content) async {
  final tmp = File(_tempPath(file));
  try {
    await tmp.writeAsString(content, flush: true);
    return tmp;
  } catch (_) {
    await _deleteIfPresent(tmp);
    rethrow;
  }
}

Future<void> writeAtomically(File file, String content) async {
  final tmp = await stageAtomically(file, content);
  try {
    await commitStagedAtomically(tmp, file);
  } finally {
    await _deleteIfPresent(tmp);
  }
}

/// Renames a staged file over [target], removing the staged path on failure.
Future<void> commitStagedAtomically(File staged, File target) async {
  try {
    await staged.rename(target.path);
  } on FileSystemException {
    if (!Platform.isWindows ||
        await FileSystemEntity.type(target.path) != FileSystemEntityType.file) {
      rethrow;
    }

    // Keep the old file until the staged rename succeeds. A failed second
    // rename must put the original back rather than leave the target missing.
    final rollback = File(_tempPath(target));
    await target.rename(rollback.path);
    try {
      await staged.rename(target.path);
    } catch (_) {
      if (await FileSystemEntity.type(target.path) ==
          FileSystemEntityType.notFound) {
        await rollback.rename(target.path);
      }
      rethrow;
    }
    await rollback.delete();
  }
}

Future<void> _deleteIfPresent(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    // Cleanup is best-effort; never hide the original write/rename failure.
  }
}
