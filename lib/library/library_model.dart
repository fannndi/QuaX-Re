import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';

const _nomedia = '.nomedia';
const libraryFolderName = 'QuaXLibrary';

// Patched in MainActivity.kt: checks/opens Android's all-files-access screen,
// which is what plain dart:io writes to a picked folder (with an SD card!)
// depend on since scoped storage. Also serves the video-thumbnail handler.
const MethodChannel _storageChannel = MethodChannel('browser_resolver');

const _videoExtensions = [
  '.mp4', '.mov', '.webm', '.mkv', '.m4v', '.avi', '.ts', '.3gp', '.mpeg', '.mpg', '.wmv', '.flv',
  '.m2ts', '.ogv'
];
const _imageExtensions = ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.heic', '.heif', '.avif', '.tiff'];

const _mimeTypes = {
  '.mp4': 'video/mp4',
  '.mov': 'video/quicktime',
  '.webm': 'video/webm',
  '.mkv': 'video/x-matroska',
  '.m4v': 'video/mp4',
  '.avi': 'video/x-msvideo',
  '.ts': 'video/mp2t',
  '.3gp': 'video/3gpp',
  '.mpeg': 'video/mpeg',
  '.mpg': 'video/mpeg',
  '.wmv': 'video/x-ms-wmv',
  '.flv': 'video/x-flv',
  '.m2ts': 'video/mp2t',
  '.ogv': 'video/ogg',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.bmp': 'image/bmp',
  '.heic': 'image/heic',
  '.heif': 'image/heif',
  '.avif': 'image/avif',
  '.tiff': 'image/tiff',
};

class LibraryEntry {
  final File file;
  final bool isVideo;
  final int size;
  final DateTime modified;

  LibraryEntry(this.file, this.isVideo, {this.size = 0, DateTime? modified})
      : name = p.basename(file.path),
        modified = modified ?? DateTime.fromMillisecondsSinceEpoch(0);

  final String name;

  double get sizeMb => size / 1048576;
}

/// State of the Hentoid-style hidden library: a folder the user picked from
/// the device storage (visible in file managers), holding every downloaded
/// media and a `.nomedia` marker that keeps gallery apps from indexing it.
class LibraryModel extends Store<List<LibraryEntry>> {
  final BasePrefService prefs;

  LibraryModel(this.prefs) : super([]);

  String get libraryPath => prefs.get<String>(optionLibraryPath) ?? '';

  bool get isConfigured => libraryPath.isNotEmpty;

  /// Whether the library is listed by gallery apps: true means the `.nomedia`
  /// marker is gone.
  bool get galleryVisible => prefs.get<bool>(optionLibraryVisibleInGallery) ?? false;

  /// Live toggle for the gallery apps: drops/creates the `.nomedia` marker and
  /// asks Android to rescan the folder, so the videos appear or disappear from
  /// the system gallery without a restart.
  Future<bool> setGalleryVisible(bool visible) async {
    final path = libraryPath;
    if (path.isEmpty) return false;

    try {
      final ok = await _storageChannel.invokeMethod<bool>('setGalleryVisibility', {
        'path': path,
        'visible': visible,
      });
      if (ok != true) return false;

      prefs.set<bool>(optionLibraryVisibleInGallery, visible);
      return true;
    } on Exception {
      return false;
    }
  }

  /// Cached thumbnail of a video, generated once by the Android handler
  /// (MediaMetadataRetriever one second in). Serves both the grid tile and the
  /// viewer's poster, so a downloaded clip never shows as a black frame.
  Future<String?> thumbnailFor(LibraryEntry entry) async {
    try {
      final cacheDir = Directory(p.join((await getTemporaryDirectory()).path, 'thumbs'));
      await cacheDir.create(recursive: true);
      final cached = File(p.join(cacheDir.path, '${p.basenameWithoutExtension(entry.file.path)}.jpg'));
      if (await cached.exists()) {
        return cached.path;
      }

      return await _storageChannel.invokeMethod<String>('videoThumbnail',
          {'path': entry.file.path, 'outPath': cached.path});
    } on Exception {
      return null;
    }
  }

  /// Opens a library file through the system player/viewer. No in-app player:
  /// the file URI is granted to the chosen app directly, so the folder stays
  /// hidden from the gallery while clips play like any other media file.
  Future<bool> openExternally(String path) async {
    final mime = _mimeTypes[p.extension(path).toLowerCase()] ?? '*/*';
    try {
      final ok = await _storageChannel.invokeMethod<bool>('openMediaFile', {
        'path': path,
        'mime': mime,
      });
      return ok == true;
    } on Exception {
      return false;
    }
  }

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

      // Hidden by default: the gallery-killer marker itself, Hentoid-style.
      // With the Download tab's live toggle on, no marker is written, so the
      // system gallery indexes the folder like any other media directory.
      final nomedia = File(p.join(root.path, _nomedia));
      final visible = prefs.get<bool>(optionLibraryVisibleInGallery) ?? false;
      if (visible && await nomedia.exists()) {
        await nomedia.delete();
      } else if (!visible && !await nomedia.exists()) {
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

  /// Counts media files that sit directly in [sourcePath] — old downloads from
  /// before the library existed, or files another app left in a shared folder.
  Future<int> countImportableIn(String sourcePath) async {
    try {
      final sourceDir = Directory(sourcePath);
      if (!await sourceDir.exists()) return 0;

      var count = 0;
      await for (final entity in sourceDir.list()) {
        if (entity is File && _isMedia(entity.path)) count++;
      }
      return count;
    } on Exception {
      return 0;
    }
  }

  /// Moves the media files sitting directly in [sourcePath] into the library
  /// — copies each file, then removes the source (Hentoid's import flow).
  Future<bool> importFromDirectory(String sourcePath) async {
    if (libraryPath.isEmpty) return false;

    try {
      final sourceDir = Directory(sourcePath);
      if (!await sourceDir.exists()) return false;

      await for (final entity in sourceDir.list()) {
        if (entity is! File || !_isMedia(entity.path)) continue;

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

  /// Moves all media files from a folder the user picks into the library —
  /// the door for downloads made before the library existed (or from apps
  /// like WhatsApp).
  Future<bool> importExisting() async {
    if (libraryPath.isEmpty) {
      final picked = await FilePicker.getDirectoryPath();
      if (picked == null) return false;
      if (!await _configureAt(picked)) return false;
    }

    final source = await FilePicker.getDirectoryPath();
    if (source == null) return false;

    return importFromDirectory(source);
  }

  bool _isMedia(String path) {
    final extension = p.extension(path).toLowerCase();
    return _imageExtensions.contains(extension) || _videoExtensions.contains(extension);
  }

  Future<void> refresh() async {
    await execute(() async {
      final dir = Directory(libraryPath);
      if (!await dir.exists()) {
        return <LibraryEntry>[];
      }

      final entries = <LibraryEntry>[];
      // Recursive: imported libraries (or files the user nested) still show up.
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final extension = p.extension(entity.path).toLowerCase();
        final isVideo = _videoExtensions.contains(extension);
        if (!isVideo && !_imageExtensions.contains(extension)) continue;

        var modified = DateTime.fromMillisecondsSinceEpoch(0);
        var size = 0;
        try {
          final stat = entity.statSync();
          modified = stat.modified;
          size = stat.size;
        } catch (_) {
          // Unreadable file: keep it listed with empty metadata.
        }
        entries.add(LibraryEntry(entity, isVideo, size: size, modified: modified));
      }

      entries.sort((a, b) => b.modified.compareTo(a.modified));
      return entries;
    });
  }
}
