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

/// Outcome of a gallery show/hide pass: [affected] media files entered (or
/// left) the gallery, [remaining] says how many rows stayed behind in the
/// media database after hiding (0 means fully hidden).
class GalleryVisibilityResult {
  const GalleryVisibilityResult({required this.ok, this.affected = 0, this.remaining = 0});

  static const failed = GalleryVisibilityResult(ok: false);

  final bool ok;
  final int affected;
  final int remaining;
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
  /// the system gallery without a restart. Resolves only after the native side
  /// finished the whole pass (scans included), reporting how many files were
  /// touched and how many stayed visible.
  Future<GalleryVisibilityResult> setGalleryVisible(bool visible) async {
    final path = libraryPath;
    if (path.isEmpty) return GalleryVisibilityResult.failed;

    try {
      final outcome = await _storageChannel.invokeMapMethod<String, dynamic>('setGalleryVisibility', {
        'path': path,
        'visible': visible,
      });
      if (outcome == null) return GalleryVisibilityResult.failed;

      prefs.set<bool>(optionLibraryVisibleInGallery, visible);
      return GalleryVisibilityResult(
        ok: true,
        affected: (outcome['affected'] as num?)?.toInt() ?? 0,
        remaining: (outcome['remaining'] as num?)?.toInt() ?? 0,
      );
    } on Exception {
      return GalleryVisibilityResult.failed;
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

  /// The library file matching a media URL, or null when it was never
  /// downloaded. Downloads keep the URL basename; a duplicate gets a
  /// `-timestamp` suffix, so the stem is compared too.
  Future<String?> localPathFor(String url) async {
    if (libraryPath.isEmpty) return null;

    final name = p.basename(url.split('?').first);
    if (name.isEmpty) return null;

    final direct = File(p.join(libraryPath, name));
    if (await direct.exists()) return direct.path;

    await _buildNameIndexIfStale();
    final exact = _localNames[name];
    if (exact != null) return exact;

    final stem = p.basenameWithoutExtension(name).toLowerCase();
    final extension = p.extension(name).toLowerCase();
    for (final entry in _localNames.entries) {
      if (p.extension(entry.key).toLowerCase() != extension) continue;
      if (p.basenameWithoutExtension(entry.key).toLowerCase().startsWith('$stem-')) {
        return entry.value;
      }
    }
    return null;
  }

  final Map<String, String> _localNames = {};
  DateTime _namesBuiltAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _buildNameIndexIfStale() async {
    final now = DateTime.now();
    if (_localNames.isNotEmpty && now.difference(_namesBuiltAt).inMinutes < 5) return;

    _namesBuiltAt = now;
    _localNames.clear();
    try {
      final dir = Directory(libraryPath);
      if (!await dir.exists()) return;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) _localNames[p.basename(entity.path)] = entity.path;
      }
    } catch (_) {
      // An unreadable folder simply yields no local matches.
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

      if (visible) {
        // A picked folder can already hold media: index it right away, so the
        // gallery switch means what it says from the first run.
        await _storageChannel.invokeMethod('setGalleryVisibility', {
          'path': root.path,
          'visible': true,
        });
      }
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
