import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:path/path.dart' as p;
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';

const _nomedia = '.nomedia';
const libraryFolderName = 'QuaXLibrary';

// Patched in MainActivity.kt: checks/opens Android's all-files-access screen,
// which is what plain dart:io writes to a picked folder (with an SD card!)
// depend on since scoped storage.
const MethodChannel _storageChannel = MethodChannel('browser_resolver');

const _videoExtensions = ['.mp4', '.mov', '.webm', '.mkv', '.m4v'];
const _imageExtensions = ['.jpg', '.jpeg', '.png', '.webp', '.gif'];

class LibraryEntry {
  final File file;
  final bool isVideo;

  LibraryEntry(this.file, this.isVideo) : name = p.basename(file.path);

  final String name;
}

/// State of the Hentoid-style hidden library: a folder the user picked from
/// the device storage (visible in file managers), holding every downloaded
/// media and a `.nomedia` marker that keeps gallery apps from indexing it.
class LibraryModel extends Store<List<LibraryEntry>> {
  final BasePrefService prefs;

  LibraryModel(this.prefs) : super([]);

  String get libraryPath => prefs.get<String>(optionLibraryPath) ?? '';

  bool get isConfigured => libraryPath.isNotEmpty;

  /// Configures [pickedPath] into the hidden library root, without running the
  /// system picker (the settings screen picks the folder itself).
  ///
  /// Fails (returns false, [error] filled) when the pick landed on storage the
  /// plain file API cannot write to — most often the SD card without Android's
  /// all-files-access grant (Hentoid solves it with SAF; this fork opens the
  /// all-files-access screen instead of carrying a whole SAF tree).
  Future<bool> setupLibraryAt(String pickedPath, {ValueNotifier<String?>? error}) {
    return _configureAt(pickedPath, error: error);
  }

  /// Shows the system picker, creates the hidden subfolder, writes the
  /// `.nomedia` marker and remembers it. Returns false when no folder was
  /// chosen or the folder refused writes.
  Future<bool> setupLibrary({ValueNotifier<String?>? error}) async {
    final picked = await FilePicker.getDirectoryPath();
    if (picked == null) return false;

    return _configureAt(picked, error: error);
  }

  Future<bool> _configureAt(String pickedPath, {ValueNotifier<String?>? error}) async {
    try {
      final granted = await _storageChannel.invokeMethod<bool>('hasAllFilesAccess');
      if (granted != true) {
        await _storageChannel.invokeMethod('requestAllFilesAccess');
        error?.value = 'storage_permission_needed';
        return false;
      }

      final root = Directory(p.join(pickedPath, libraryFolderName));
      await root.create(recursive: true);

      // The gallery-killer itself: one empty marker file, Hentoid-style. Gallery
      // apps ignore the subtree it sits in; file managers still see the folder.
      final nomedia = File(p.join(root.path, _nomedia));
      if (!await nomedia.exists()) {
        await nomedia.create();
      }

      prefs.set<String>(optionLibraryPath, root.path);
      update([]);
      return true;
    } on Exception catch (e) {
      error?.value = e.toString();
      return false;
    }
  }

  /// Moves all media files from a folder the user picks into the library —
  /// the door for downloads made before the library existed (or from apps
  /// like WhatsApp). Copies each file, then removes the source.
  Future<bool> importExisting() async {
    if (libraryPath.isEmpty) {
      final picked = await FilePicker.getDirectoryPath();
      if (picked == null) return false;
      if (!await _configureAt(picked)) return false;
    }

    final source = await FilePicker.getDirectoryPath();
    if (source == null) return false;

    try {
      final sourceDir = Directory(source);
      if (!await sourceDir.exists()) return false;

      await for (final entity in sourceDir.list()) {
        if (entity is! File) continue;
        final extension = p.extension(entity.path).toLowerCase();
        final isMedia = _imageExtensions.contains(extension) || _videoExtensions.contains(extension);
        if (!isMedia) continue;

        var target = p.join(libraryPath, p.basename(entity.path));
        // Keep copies of the same basename alive: prefix with the timestamp.
        if (await File(target).exists()) {
          target = p.join(
              libraryPath,
              '${p.basenameWithoutExtension(entity.path)}-${DateTime.now().millisecondsSinceEpoch}'
              '${p.extension(entity.path)}');
        }
        await entity.copy(target);
        await entity.delete();
      }

      await refresh();
      return true;
    } on Exception {
      return false;
    }
  }

  Future<void> refresh() async {
    await execute(() async {
      final dir = Directory(libraryPath);
      if (!await dir.exists()) {
        return <LibraryEntry>[];
      }

      final entries = <LibraryEntry>[];
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final extension = p.extension(entity.path).toLowerCase();
        if (_imageExtensions.contains(extension)) {
          entries.add(LibraryEntry(entity, false));
        } else if (_videoExtensions.contains(extension)) {
          entries.add(LibraryEntry(entity, true));
        }
      }

      entries.sort((a, b) => _modifiedOf(b).compareTo(_modifiedOf(a)));
      return entries;
    });
  }

  DateTime _modifiedOf(LibraryEntry entry) {
    try {
      return entry.file.lastModifiedSync();
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }
}
