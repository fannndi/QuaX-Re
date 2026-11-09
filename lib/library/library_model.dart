import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';
import 'package:quax/utils/lru_cache.dart';

const _nomedia = '.nomedia';
const libraryFolderName = 'QuaXLibrary';

/// A dot keeps the hidden root out of file managers that still reach
/// `Android/data` (Android 10 with legacy storage). On Android 11+ the whole
/// `Android/data/<package>` tree is already off-limits to other apps.
const hiddenLibraryFolderName = '.QuaXLibrary';

const _spaceMarginBytes = 16 * 1024 * 1024;

// Patched in MainActivity.kt: checks/opens Android's all-files-access screen,
// which is what plain dart:io writes to a picked folder (with an SD card!)
// depend on since scoped storage. Also serves the video-thumbnail handler.
const _storageChannel = quaxMethodChannel;

const _videoExtensions = [
  '.mp4', '.mov', '.webm', '.mkv', '.m4v', '.avi', '.ts', '.3gp', '.mpeg', '.mpg', '.wmv', '.flv',
  '.m2ts', '.ogv'
];
const _imageExtensions = ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.heic', '.heif', '.avif', '.tiff'];

/// Thumbnail file name for a library-relative path. Hashing the path keeps two
/// nested clips with the same basename from sharing (and overwriting) one frame.
@visibleForTesting
String thumbnailNameFor(String relativePath) => '${md5.convert(utf8.encode(relativePath))}.jpg';

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

enum LibraryStorageMode { hidden, visible }

/// One storage volume that can hold the hidden library. `appFilesRoot` is the
/// app-specific directory (`.../Android/data/<package>/files`), which needs no
/// storage permission and is invisible to other apps on Android 11+.
class LibraryVolume {
  const LibraryVolume(this.appFilesRoot);

  final String appFilesRoot;

  /// App-specific dirs on the primary volume look like
  /// `/storage/emulated/0/...`; a removable card arrives as
  /// `/storage/XXXX-XXXX/...`.
  bool get isPrimary => appFilesRoot.startsWith('/storage/emulated/');

  String get hiddenRoot => p.join(appFilesRoot, hiddenLibraryFolderName);

  /// `/storage/emulated/0/Android/data/...` -> `/storage/emulated/0`.
  String get volumeRoot {
    final parts = p.split(appFilesRoot);
    final android = parts.indexOf('Android');
    if (android > 0) return p.joinAll(parts.sublist(0, android));
    return p.dirname(appFilesRoot);
  }

  /// Account backups live outside the media tree, on the same volume, so an
  /// uninstall can delete the hidden library without touching the vault.
  String get vaultRoot => p.join(volumeRoot, 'QuaX-Re');

  @override
  bool operator ==(Object other) => other is LibraryVolume && other.appFilesRoot == appFilesRoot;

  @override
  int get hashCode => appFilesRoot.hashCode;
}

class LibraryMoveResult {
  const LibraryMoveResult({required this.moved, required this.failed, this.error});

  const LibraryMoveResult.failed(this.error) : moved = 0, failed = 0;

  final int moved;
  final int failed;
  final String? error;

  bool get ok => error == null && failed == 0;
}

class LibraryExportResult {
  const LibraryExportResult({required this.copied, required this.failed, this.path, this.error});

  const LibraryExportResult.failed(this.error) : copied = 0, failed = 0, path = null;

  final int copied;
  final int failed;
  final String? path;
  final String? error;

  bool get ok => error == null && failed == 0;
}

/// State of the downloaded-media library.
///
/// `visible` is the original Hentoid-style folder the reader picked, with a
/// `.nomedia` marker: file managers still list it. `hidden` moves the media
/// into the app-specific external directory on the chosen volume, which other
/// apps cannot reach on Android 11+ and which a dot-prefixed folder keeps out
/// of sight on Android 10 legacy file managers.
class LibraryModel extends Store<List<LibraryEntry>> {
  final BasePrefService prefs;
  LibraryModel(this.prefs) : super([]);

  /// Test seam: path_provider has no plugin in the unit-test binary.
  @visibleForTesting
  static Future<List<Directory>?> Function()? debugExternalDirectories;

  String get libraryPath => prefs.get<String>(optionLibraryPath) ?? '';

  bool get isConfigured => libraryPath.isNotEmpty;

  LibraryStorageMode get storageMode {
    final value = prefs.get<String>(optionLibraryStorageMode);
    if (value == libraryStorageHidden) return LibraryStorageMode.hidden;
    if (value == libraryStorageVisible) return LibraryStorageMode.visible;

    // Older builds stored only the path. A path under Android/data could only
    // have come from hidden setup, so infer it instead of showing the visible
    // folder controls over it.
    final path = libraryPath;
    if (path.contains('${p.separator}Android${p.separator}data${p.separator}')) {
      return LibraryStorageMode.hidden;
    }
    return LibraryStorageMode.visible;
  }

  bool get isHidden => storageMode == LibraryStorageMode.hidden;

  /// Whether the configured root sits on a removable card. Used by the status
  /// row to say "SD card" instead of printing an `Android/data` path nobody
  /// needs to read.
  bool get isOnRemovableStorage {
    final parts = p.split(libraryPath);
    return parts.length > 2 && parts[1] == 'storage' && parts[2] != 'emulated';
  }

  /// Every volume the app can write to without a permission prompt. The
  /// primary volume comes first so the UI has a sane default; a removable card
  /// is what makes the "set it on the SD card" flow possible.
  Future<List<LibraryVolume>> availableVolumes() async {
    final dirs = await (debugExternalDirectories?.call() ?? getExternalStorageDirectories());
    if (dirs == null) return const [];

    final volumes = <LibraryVolume>[];
    for (final dir in dirs) {
      final volume = LibraryVolume(dir.path);
      if (!volumes.contains(volume)) volumes.add(volume);
    }
    volumes.sort((a, b) {
      if (a.isPrimary == b.isPrimary) return a.appFilesRoot.compareTo(b.appFilesRoot);
      return a.isPrimary ? -1 : 1;
    });
    return volumes;
  }

  /// Whether the configured folder still exists. A removed SD card must show a
  /// reconnect screen, not silently launch the folder picker.
  Future<bool> get storageAvailable async {
    final path = libraryPath;
    return path.isNotEmpty && await Directory(path).exists();
  }

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
    // MediaStore cannot index Android/data; the switch has no meaning there.
    if (isHidden) return GalleryVisibilityResult.failed;

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

  /// Thumbnails already asked about, keyed by file path. The disk cache under
  /// `thumbs/` remembers the answer; this remembers the *call*. Both the gallery
  /// and the local search hand `thumbnailFor` straight to a FutureBuilder, so
  /// without it every rebuild of a tile re-ran the directory lookup, the stat
  /// and the Android call for a path that had not changed.
  final _thumbnailRequests = LruCache<String, Future<String?>>(400);

  /// Cached thumbnail of a video, generated once by the Android handler
  /// (MediaMetadataRetriever one second in). Serves both the grid tile and the
  /// viewer's poster, so a downloaded clip never shows as a black frame.
  Future<String?> thumbnailFor(LibraryEntry entry) {
    final key = entry.file.path;
    return _thumbnailRequests.get(key) ?? _requestThumbnail(entry, key);
  }

  Future<String?> _requestThumbnail(LibraryEntry entry, String key) {
    final request = _generateThumbnail(entry).then(
      (path) {
        // A null means the frame could not be read — most often a file still
        // being imported — so the miss is not remembered and the next build
        // asks about it again rather than leaving the tile blank for good.
        if (path == null) _thumbnailRequests.remove(key);
        return path;
      },
      onError: (Object _) {
        _thumbnailRequests.remove(key);
        return null;
      },
    );
    _thumbnailRequests.set(key, request);
    return request;
  }

  Future<String?> _generateThumbnail(LibraryEntry entry) async {
    try {
      final cacheDir = Directory(p.join((await getTemporaryDirectory()).path, 'thumbs'));
      await cacheDir.create(recursive: true);
      // Hash the path relative to the library, not the basename: two nested
      // clips named clip.mp4 used to share one thumbnail and show the wrong
      // frame (and a deleted clip's frame reappeared for a new one).
      final relative =
          libraryPath.isEmpty ? entry.file.path : p.relative(entry.file.path, from: libraryPath);
      final cached = File(p.join(cacheDir.path, thumbnailNameFor(relative)));
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
    final index = _nameIndexes[libraryPath] ?? const <String, List<String>>{};
    final exact = index[name];
    if (exact != null && exact.isNotEmpty) return exact.first;

    final stem = p.basenameWithoutExtension(name).toLowerCase();
    final extension = p.extension(name).toLowerCase();
    for (final entry in index.entries) {
      if (p.extension(entry.key).toLowerCase() != extension) continue;
      if (p.basenameWithoutExtension(entry.key).toLowerCase().startsWith('$stem-')) {
        if (entry.value.isNotEmpty) return entry.value.first;
      }
    }
    return null;
  }

  // The name index is shared by every LibraryModel for the same folder: the
  // video player builds a fresh model per tile, so a per-instance index meant
  // a full recursive scan every time a clip came into view.
  static final Map<String, Map<String, List<String>>> _nameIndexes = {};
  static final Map<String, DateTime> _nameIndexBuiltAt = {};
  static final Map<String, Future<void>> _nameIndexBuilding = {};

  Future<void> _buildNameIndexIfStale() async {
    final path = libraryPath;
    if (path.isEmpty) return;

    final builtAt = _nameIndexBuiltAt[path];
    if (builtAt != null && DateTime.now().difference(builtAt).inMinutes < 5) return;

    final building = _nameIndexBuilding[path];
    if (building != null) {
      // There is already an index in memory and a scan running: serve the old
      // one now instead of blocking the player on the directory walk.
      if (builtAt != null) return;
      await building;
      return;
    }

    final index = _nameIndexes[path] ??= {};
    final future = _scanNames(path, index);
    _nameIndexBuilding[path] = future;

    if (builtAt == null) {
      // First use: the caller has nothing to fall back to, so it has to wait.
      try {
        await future;
      } finally {
        _nameIndexBuilding.remove(path);
      }
      return;
    }

    // A stale index is still usable. Refresh it behind the current frame; the
    // next lookup sees the new names, and this one never blocks playback.
    future.whenComplete(() => _nameIndexBuilding.remove(path));
  }

  @visibleForTesting
  static int debugNameIndexBuilds = 0;

  Future<void> _scanNames(String path, Map<String, List<String>> index) async {
    debugNameIndexBuilds++;
    final scanned = <String, List<String>>{};
    try {
      final dir = Directory(path);
      if (await dir.exists()) {
        await for (final entity in dir.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          (scanned[name] ??= []).add(entity.path);
        }
      }
    } catch (_) {
      // An unreadable folder simply yields no local matches.
    }

    index
      ..clear()
      ..addAll(scanned);
    _nameIndexBuiltAt[path] = DateTime.now();
  }

  /// Drops the shared index after the folder's contents changed.
  void _invalidateNameIndex() => _invalidateNameIndexAt(libraryPath);

  void _invalidateNameIndexAt(String path) {
    if (path.isEmpty) return;
    _nameIndexes.remove(path);
    _nameIndexBuiltAt.remove(path);
  }

  /// Configures the library into the app-private directory of [volume]. No
  /// storage permission is involved: the app owns this tree, and Android keeps
  /// it away from other apps on 11+.
  Future<bool> setupHiddenLibrary(LibraryVolume volume, {ValueNotifier<String?>? error}) async {
    try {
      final root = Directory(volume.hiddenRoot);
      await root.create(recursive: true);
      await _ensureNomedia(root);
      await prefs.set<String>(optionLibraryPath, root.path);
      await prefs.set<String>(optionLibraryStorageMode, libraryStorageHidden);
      await prefs.set<bool>(optionLibraryVisibleInGallery, false);
      await _pinVaultRoot(volume);
      _invalidateNameIndexAt(root.path);
      update([]);
      return true;
    } on Exception catch (e) {
      error?.value = e.toString();
      return false;
    }
  }

  /// Moves the current media into [volume]'s hidden directory and switches the
  /// library there. Callers pause the download queue first; a transfer that
  /// lands mid-move would save into the folder that is being emptied.
  Future<LibraryMoveResult> moveToHidden(LibraryVolume volume) async {
    final result = await _moveRoot(Directory(volume.hiddenRoot), mode: LibraryStorageMode.hidden);
    if (result.error == null) await _pinVaultRoot(volume);
    return result;
  }

  /// Moves the current media into `<pickedParent>/QuaXLibrary` and switches to
  /// the visible mode. The vault root deliberately stays where it is: account
  /// backups must not follow a media folder into app-private storage.
  Future<LibraryMoveResult> moveToVisibleAt(String pickedParent) {
    return _moveRoot(Directory(p.join(pickedParent, libraryFolderName)),
        mode: LibraryStorageMode.visible);
  }

  Future<void> _pinVaultRoot(LibraryVolume volume) async {
    final current = prefs.get<String>(optionVaultRoot) ?? '';
    if (current.isNotEmpty) return;
    await prefs.set<String>(optionVaultRoot, volume.vaultRoot);
  }

  Future<LibraryMoveResult> _moveRoot(Directory target, {required LibraryStorageMode mode}) async {
    final sourcePath = libraryPath;
    final sourceWasVisible = !isHidden;
    if (sourcePath.isEmpty) {
      try {
        await _configureTarget(target, mode);
      } catch (e) {
        return LibraryMoveResult.failed(e.toString());
      }
      return const LibraryMoveResult(moved: 0, failed: 0);
    }

    if (p.equals(sourcePath, target.path)) {
      try {
        await _configureTarget(target, mode);
        await refresh();
      } catch (e) {
        return LibraryMoveResult.failed(e.toString());
      }
      return const LibraryMoveResult(moved: 0, failed: 0);
    }

    // Moving a library into itself (or over its own parent) would copy the
    // target into the source while walking it. Refuse before touching a file.
    if (p.isWithin(sourcePath, target.path) || p.isWithin(target.path, sourcePath)) {
      return const LibraryMoveResult.failed('inside_library');
    }

    // Sizes come from the scan, and the free-space check is useless without
    // them. This also means a library that was never opened still moves
    // correctly.
    await refresh();
    final totalBytes = state.fold<int>(0, (sum, entry) => sum + entry.size);
    // A same-volume move is a rename and needs no free space; checking it
    // would refuse to tidy a nearly full disk that has nothing to copy.
    if (!_sameStorage(sourcePath, target.path)) {
      final free = await _availableSpace(target.path);
      if (free != null && totalBytes + _spaceMarginBytes > free) {
        return const LibraryMoveResult.failed('no_space');
      }
    }

    final source = Directory(sourcePath);
    if (!await source.exists()) {
      try {
        await _configureTarget(target, mode);
        await refresh();
      } catch (e) {
        return LibraryMoveResult.failed(e.toString());
      }
      return const LibraryMoveResult(moved: 0, failed: 0);
    }

    try {
      await target.create(recursive: true);
    } catch (e) {
      return LibraryMoveResult.failed(e.toString());
    }

    var moved = 0;
    var failed = 0;
    try {
      // Collect first: moving entries out of a directory while its lazy
      // listing is still walking it can skip files on some filesystems.
      final files = <File>[];
      await for (final entity in source.list(recursive: true, followLinks: false)) {
        if (entity is File) files.add(entity);
      }

      for (final entity in files) {
        final relative = p.relative(entity.path, from: sourcePath);
        if (p.basename(relative) == _nomedia) continue;

        try {
          var destination = p.join(target.path, relative);
          await Directory(p.dirname(destination)).create(recursive: true);
          if (await File(destination).exists()) destination = _uniqueDestination(destination);

          try {
            // Same volume: rename is atomic and copies nothing. Across the SD
            // card boundary Android refuses the rename, so fall back to a
            // copy that only deletes the source after it succeeded.
            await entity.rename(destination);
          } on FileSystemException {
            await entity.copy(destination);
            await entity.delete();
          }
          moved++;
        } catch (_) {
          // One unreadable file must not abandon the rest of the library.
          failed++;
        }
      }
    } catch (e) {
      return LibraryMoveResult(moved: moved, failed: failed, error: e.toString());
    }

    try {
      await _configureTarget(target, mode);
    } catch (e) {
      return LibraryMoveResult(moved: moved, failed: failed, error: e.toString());
    }

    // Leave the old folder alone when a failed file is still in it; deleting
    // it recursively would destroy the only copy.
    try {
      if (await _onlyNomediaRemains(source)) {
        if (sourceWasVisible) {
          // The old folder may still have MediaStore rows from when the gallery
          // switch was on. Re-applying the marker before deleting it makes the
          // provider drop those rows instead of showing broken thumbnails.
          try {
            await _storageChannel.invokeMethod('setGalleryVisibility', {
              'path': sourcePath,
              'visible': false,
            });
          } on Exception {
            // The folder is about to disappear; a failed scan changes nothing.
          }
        }
        await source.delete(recursive: true);
      }
    } catch (_) {
      // A folder that refuses deletion is harmless.
    }

    await refresh();
    return LibraryMoveResult(moved: moved, failed: failed);
  }

  Future<void> _configureTarget(Directory target, LibraryStorageMode mode) async {
    await target.create(recursive: true);
    final marker = File(p.join(target.path, _nomedia));
    final visible = prefs.get<bool>(optionLibraryVisibleInGallery) ?? false;

    if (mode == LibraryStorageMode.hidden) {
      await _ensureNomedia(target);
      await prefs.set<bool>(optionLibraryVisibleInGallery, false);
    } else if (visible) {
      if (await marker.exists()) await marker.delete();
    } else {
      await _ensureNomedia(target);
    }

    final oldPath = libraryPath;
    await prefs.set<String>(optionLibraryPath, target.path);
    await prefs.set<String>(
      optionLibraryStorageMode,
      mode == LibraryStorageMode.hidden ? libraryStorageHidden : libraryStorageVisible,
    );
    _invalidateNameIndexAt(oldPath);
    _invalidateNameIndexAt(target.path);
    update([]);

    if (mode == LibraryStorageMode.visible && visible) {
      try {
        // A picked folder can already hold media: index it right away, so the
        // gallery switch means what it says from the first run.
        await _storageChannel.invokeMethod('setGalleryVisibility', {
          'path': target.path,
          'visible': true,
        });
      } on Exception {
        // The folder still works; the switch can retry the scan.
      }
    }
  }

  Future<void> _ensureNomedia(Directory root) async {
    final marker = File(p.join(root.path, _nomedia));
    if (!await marker.exists()) await marker.create();
  }

  Future<bool> _onlyNomediaRemains(Directory dir) async {
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && p.basename(entity.path) != _nomedia) return false;
    }
    return true;
  }

  /// Whether two paths live on the same mounted volume. Android exposes the
  /// primary storage as `/storage/emulated/<user>` and a card as
  /// `/storage/<uuid>`; a rename between the two is refused.
  bool _sameStorage(String a, String b) {
    final pa = p.split(a);
    final pb = p.split(b);
    if (pa.length < 3 || pb.length < 3) return true;
    if (pa[1] != 'storage' || pb[1] != 'storage') return true;
    if (pa[2] != pb[2]) return false;
    if (pa[2] == 'emulated') {
      return pa.length > 3 && pb.length > 3 && pa[3] == pb[3];
    }
    return true;
  }

  static int _collisionSequence = 0;

  String _uniqueDestination(String path) {
    final stem = p.basenameWithoutExtension(path);
    final extension = p.extension(path);
    final suffix = '${DateTime.now().millisecondsSinceEpoch}-${_collisionSequence++}';
    return p.join(p.dirname(path), '$stem-$suffix$extension');
  }

  Future<int?> _availableSpace(String path) async {
    try {
      return await _storageChannel.invokeMethod<int>('getAvailableSpace', {'path': path});
    } on Exception {
      return null;
    }
  }

  /// Asks for the all-files grant the visible mode and exports need. Hidden
  /// storage itself never asks: the app owns its `Android/data` tree.
  Future<bool> ensureStorageAccess() async {
    try {
      var granted = await _storageChannel.invokeMethod<bool>('hasAllFilesAccess');
      if (granted != true) {
        granted = await _storageChannel.invokeMethod<bool>('requestAllFilesAccess');
      }
      if (granted != true) {
        granted = await _storageChannel.invokeMethod<bool>('hasAllFilesAccess');
      }
      return granted == true;
    } on Exception {
      return false;
    }
  }

  /// Copies the whole library (or just [entries]) into a new
  /// `<destinationParent>/QuaX-Re Export` folder. Hidden media cannot be
  /// reached from a file manager or survive an uninstall, so this is the way
  /// out for the reader.
  Future<LibraryExportResult> exportTo(String destinationParent,
      {List<LibraryEntry>? entries}) async {
    final sourcePath = libraryPath;
    if (sourcePath.isEmpty) return const LibraryExportResult.failed('not_configured');

    final selected = entries ?? state;
    if (selected.isEmpty) return const LibraryExportResult.failed('empty');
    if (p.equals(destinationParent, sourcePath) || p.isWithin(sourcePath, destinationParent)) {
      // Putting the export inside the library would make the gallery list every
      // exported copy as a new download.
      return const LibraryExportResult.failed('inside_library');
    }

    var base = p.join(destinationParent, 'QuaX-Re Export');
    if (await Directory(base).exists()) {
      base = '$base-${DateTime.now().millisecondsSinceEpoch}';
    }
    final target = Directory(base);
    try {
      await target.create(recursive: true);
    } catch (e) {
      return LibraryExportResult.failed(e.toString());
    }

    final totalBytes = selected.fold<int>(0, (sum, entry) => sum + entry.size);
    final free = await _availableSpace(target.path);
    if (free != null && totalBytes + _spaceMarginBytes > free) {
      return const LibraryExportResult.failed('no_space');
    }

    var copied = 0;
    var failed = 0;
    for (final entry in selected) {
      try {
        final relative = p.isWithin(sourcePath, entry.file.path)
            ? p.relative(entry.file.path, from: sourcePath)
            : entry.name;
        var destination = p.join(target.path, relative);
        await Directory(p.dirname(destination)).create(recursive: true);
        if (await File(destination).exists()) destination = _uniqueDestination(destination);
        await entry.file.copy(destination);
        copied++;
      } catch (_) {
        failed++;
      }
    }

    return LibraryExportResult(copied: copied, failed: failed, path: target.path);
  }

  /// Configures [pickedPath] into the visible library root, without running the
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
      // Android 10 and below answer the request only after the user has chosen
      // in the runtime dialog; Android 11+ opens the all-files screen, and the
      // grant only shows on the next check (activity resume).
      final granted = await ensureStorageAccess();
      if (!granted) {
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

      await prefs.set<String>(optionLibraryPath, root.path);
      await prefs.set<String>(optionLibraryStorageMode, libraryStorageVisible);
      // Backup folder: the parent the reader picked, exactly where the old
      // sibling-QuaXAccount layout already put it.
      if ((prefs.get<String>(optionVaultRoot) ?? '').isEmpty) {
        await prefs.set<String>(optionVaultRoot, pickedPath);
      }
      _invalidateNameIndexAt(root.path);
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

    final sourceDir = Directory(sourcePath);
    if (!await sourceDir.exists()) return false;

    // Importing the library into itself used to rename every file with a
    // timestamp, because every target "already existed".
    if (p.equals(sourcePath, libraryPath) || p.isWithin(libraryPath, sourcePath)) {
      return false;
    }

    var allMoved = true;
    try {
      await for (final entity in sourceDir.list()) {
        if (entity is! File || !_isMedia(entity.path)) continue;

        try {
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
        } catch (_) {
          // One unreadable file must not abandon the rest of the batch.
          allMoved = false;
        }
      }
    } on Exception {
      allMoved = false;
    } finally {
      // The gallery must reflect the partial import even when it failed.
      await refresh();
    }
    return allMoved;
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
    _invalidateNameIndex();
    final path = libraryPath;
    if (path.isEmpty) {
      update([]);
      return;
    }
    await execute(() async {
      final dir = Directory(path);
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
          // Async: statSync blocked the UI isolate once per file, and a library
          // with tens of thousands of files froze the gallery for seconds.
          final stat = await entity.stat();
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
