import 'dart:convert';
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

  /// Last-read playback offset per library file (Hentoid's resume-reading
  /// idea), bounded to the 200 most-recent names.
  int? positionFor(LibraryEntry entry) {
    final map = _positions();
    return map[entry.name];
  }

  void savePosition(LibraryEntry entry, int millis) {
    try {
      final map = _positions();
      map[entry.name] = millis;
      // Bound the map so it never grows without reason.
      final entries = map.entries.toList();
      if (entries.length > 200) {
        entries.removeRange(0, entries.length - 200);
      }
      final trimmed = {for (final e in entries) e.key: e.value};
      prefs.set<String>(optionLibraryPositions, jsonEncode(trimmed));
    } on Exception {
      // positions are a nicety; losing them on a decode failure is harmless.
    }
  }

  Map<String, int> _positions() {
    final prefValue = prefs.get<String>(optionLibraryPositions);
    if (prefValue == null) return {};
    try {
      final decoded = jsonDecode(prefValue) as Map<String, dynamic>? ?? const {};
      return decoded.map((key, value) => MapEntry(key, (value as num?)?.toInt() ?? 0));
    } on Exception {
      return {};
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
