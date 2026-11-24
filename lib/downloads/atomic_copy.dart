import 'dart:io';

int _copySequence = 0;

/// Copies [source] to a sibling temp, verifies its length, then atomically
/// publishes it as [destination]. Any failure removes the partial.
Future<void> copyFileAtomically(
  File source,
  File destination, {
  int? expectedLength,
  bool preserveModified = true,
  Future<bool> Function()? shouldCommit,
}) async {
  final sourceLength = await source.length();
  if (expectedLength != null && sourceLength != expectedLength) {
    throw FileSystemException('Source length changed', source.path);
  }
  await destination.parent.create(recursive: true);
  final temp = File(
    '${destination.path}.${DateTime.now().microsecondsSinceEpoch}-'
    '${_copySequence++}.tmp',
  );
  try {
    await source.copy(temp.path);
    if (await temp.length() != sourceLength ||
        await source.length() != sourceLength) {
      throw FileSystemException(
        'Copy length verification failed',
        destination.path,
      );
    }
    if (preserveModified) {
      try {
        await temp.setLastModified((await source.stat()).modified);
      } catch (_) {
        // The bytes are still valid when a filesystem cannot preserve mtime.
      }
    }
    if (shouldCommit != null && !await shouldCommit()) {
      throw StateError('Destination changed before commit');
    }
    await _renameAtomically(temp, destination);
  } catch (_) {
    await _deleteQuietly(temp);
    rethrow;
  }
}

/// Renames on one volume, or copies-and-verifies across volumes. The source is
/// deleted only after the destination has been published and verified.
Future<void> moveFileAtomically(
  File source,
  File destination, {
  int? expectedLength,
  bool preserveModified = true,
  Future<bool> Function()? shouldCommit,
}) async {
  final sourceLength = await source.length();
  if (expectedLength != null && sourceLength != expectedLength) {
    throw FileSystemException('Source length changed', source.path);
  }
  await destination.parent.create(recursive: true);
  if (shouldCommit != null && !await shouldCommit()) {
    throw StateError('Destination changed before commit');
  }
  var renamed = false;
  try {
    await source.rename(destination.path);
    renamed = true;
  } on FileSystemException {
    // Cross-volume rename (or a desktop filesystem that refuses replacement).
  }
  if (renamed) {
    if (await destination.length() != sourceLength) {
      try {
        await destination.rename(source.path);
      } catch (_) {
        // Preserve the bytes at the destination if they cannot be restored.
      }
      throw FileSystemException(
        'Move length verification failed',
        destination.path,
      );
    }
    return;
  }
  await copyFileAtomically(
    source,
    destination,
    expectedLength: sourceLength,
    preserveModified: preserveModified,
    shouldCommit: shouldCommit,
  );
  await source.delete();
}

Future<void> _renameAtomically(File source, File destination) async {
  try {
    await source.rename(destination.path);
  } on FileSystemException {
    if (!Platform.isWindows) rethrow;
    // Android replaces the target in rename(); Windows needs this test/desktop
    // fallback. Production callers choose a unique destination first.
    if (await destination.exists()) await destination.delete();
    await source.rename(destination.path);
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    // Best-effort cleanup; the original error is more useful to the caller.
  }
}

String atomicTempPathFor(File destination) =>
    '${destination.path}.${DateTime.now().microsecondsSinceEpoch}-${_copySequence++}.tmp';
