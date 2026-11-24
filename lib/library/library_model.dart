import 'dart:async';
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
import 'package:quax/downloads/atomic_copy.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/utils/atomic_file.dart';
import 'package:quax/utils/lru_cache.dart';

const _nomedia = '.nomedia';
const _mediaLedger = '.quax-media.json';
const libraryFolderName = 'QuaXLibrary';

/// A dot keeps the hidden root out of file managers that still reach
/// `Android/data` (Android 10 with legacy storage). On Android 11+ the whole
/// `Android/data/<package>` tree is already off-limits to other apps.
const hiddenLibraryFolderName = '.QuaXLibrary';

/// Resolves a folder picked in the system picker to the library root.
///
/// The picker's natural target is the parent (the app creates `QuaXLibrary`
/// inside it), but a reader pointing at their existing library folder must not
/// end up with a second, empty `QuaXLibrary` inside it.
String libraryRootForPickedFolder(String pickedPath) {
  final picked = p.normalize(pickedPath);
  return p.basename(picked) == libraryFolderName
      ? picked
      : p.join(picked, libraryFolderName);
}

const _spaceMarginBytes = 16 * 1024 * 1024;

// Patched in MainActivity.kt: checks/opens Android's all-files-access screen,
// which is what plain dart:io writes to a picked folder (with an SD card!)
// depend on since scoped storage. Also serves the video-thumbnail handler.
const _storageChannel = quaxMethodChannel;

const _videoExtensions = [
  '.mp4',
  '.mov',
  '.webm',
  '.mkv',
  '.m4v',
  '.avi',
  '.ts',
  '.3gp',
  '.mpeg',
  '.mpg',
  '.wmv',
  '.flv',
  '.m2ts',
  '.ogv',
];
const _imageExtensions = [
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
  '.heic',
  '.heif',
  '.avif',
  '.tiff',
];

/// Thumbnail file name for a library-relative path. Hashing the path keeps two
/// nested clips with the same basename from sharing (and overwriting) one frame.
@visibleForTesting
String thumbnailNameFor(String relativePath) =>
    '${md5.convert(utf8.encode(relativePath))}.jpg';

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

/// A media folder already on disk that the reader can adopt as the library
/// without moving or copying anything.
class ExistingLibrary {
  const ExistingLibrary({
    required this.path,
    required this.mediaCount,
    required this.bytes,
    required this.isHidden,
  });

  final String path;
  final int mediaCount;
  final int bytes;
  final bool isHidden;
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
  bool operator ==(Object other) =>
      other is LibraryVolume && other.appFilesRoot == appFilesRoot;

  @override
  int get hashCode => appFilesRoot.hashCode;
}

class LibraryMoveResult {
  const LibraryMoveResult({
    required this.moved,
    required this.failed,
    this.oldRoot,
    this.failedFiles = const [],
    this.relocatedPaths = const {},
    this.error,
  });

  const LibraryMoveResult.failed(this.error)
    : moved = 0,
      failed = 0,
      oldRoot = null,
      failedFiles = const [],
      relocatedPaths = const {};

  final int moved;
  final int failed;
  final String? oldRoot;
  final List<String> failedFiles;
  final Map<String, String> relocatedPaths;
  final String? error;

  bool get ok => error == null && failed == 0;
}

class LibraryExportResult {
  const LibraryExportResult({
    required this.copied,
    required this.failed,
    this.path,
    this.error,
  });

  const LibraryExportResult.failed(this.error)
    : copied = 0,
      failed = 0,
      path = null;

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

  /// Test seam: the storage MethodChannel is not available in the unit-test
  /// binary, so tests can grant/refuse all-files access without an activity.
  @visibleForTesting
  static Future<bool> Function()? debugStorageAccess;

  @visibleForTesting
  static Directory? debugThumbnailDirectoryOverride;

  /// Test seam for the `.nomedia` pass, which also needs the MethodChannel.
  @visibleForTesting
  static Future<bool> Function(String path, bool visible)?
  debugGalleryVisibility;

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
    if (path.contains(
      '${p.separator}Android${p.separator}data${p.separator}',
    )) {
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
    final dirs =
        await (debugExternalDirectories?.call() ??
            getExternalStorageDirectories());
    if (dirs == null) return const [];

    final volumes = <LibraryVolume>[];
    for (final dir in dirs) {
      final volume = LibraryVolume(dir.path);
      if (!volumes.contains(volume)) volumes.add(volume);
    }
    volumes.sort((a, b) {
      if (a.isPrimary == b.isPrimary) {
        return a.appFilesRoot.compareTo(b.appFilesRoot);
      }
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

  /// Looks for media folders that can become the library without moving
  /// anything. The old Hentoid layout (`<volume>/X/QuaXLibrary`) and the
  /// conventional parents are checked first; one level below each volume root
  /// is walked so a renamed parent still shows up.
  Future<List<ExistingLibrary>> findExistingLibraries() async {
    final current = libraryPath;
    final candidates = <String>{};
    for (final volume in await availableVolumes()) {
      final root = volume.volumeRoot;
      candidates.addAll([
        p.join(root, libraryFolderName),
        p.join(root, 'Download', libraryFolderName),
        p.join(root, 'Documents', libraryFolderName),
        p.join(root, 'Pictures', libraryFolderName),
        p.join(root, 'Movies', libraryFolderName),
        p.join(root, 'DCIM', libraryFolderName),
        p.join(root, 'X', libraryFolderName),
        volume.hiddenRoot,
      ]);

      try {
        await for (final entity in Directory(root).list(followLinks: false)) {
          if (entity is! Directory) continue;
          final name = p.basename(entity.path);
          // Android/data is the hidden root itself; walking it would only
          // find app-private caches.
          if (name == 'Android') continue;
          candidates.add(
            name == libraryFolderName
                ? entity.path
                : p.join(entity.path, libraryFolderName),
          );
        }
      } on Exception {
        // An unmounted card still has the fixed candidates above; the folder
        // picker remains the fallback.
      }
    }

    final found = <ExistingLibrary>[];
    for (final path in candidates) {
      if (path == current) continue;
      final info = await inspectLibrary(path);
      if (info != null) found.add(info);
    }

    found.sort((a, b) {
      // A visible folder can use the gallery switch immediately; prefer it
      // over an app-private folder when both hold media.
      if (a.isHidden != b.isHidden) return a.isHidden ? 1 : -1;
      final byCount = b.mediaCount.compareTo(a.mediaCount);
      return byCount != 0 ? byCount : a.path.compareTo(b.path);
    });
    return found;
  }

  /// Counts the media in [path] so the UI can say "30 videos · 9.7 GB" before
  /// the reader adopts a folder. Returns null for a missing or empty folder.
  Future<ExistingLibrary?> inspectLibrary(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) return null;

      var count = 0;
      var bytes = 0;
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !_isMedia(entity.path)) continue;
        count++;
        try {
          bytes += await entity.length();
        } catch (_) {
          // The count still tells the reader the folder is worth adopting.
        }
      }
      if (count == 0) return null;
      return ExistingLibrary(
        path: p.normalize(path),
        mediaCount: count,
        bytes: bytes,
        isHidden: _isHiddenPath(path),
      );
    } on Exception {
      return null;
    }
  }

  /// Points the app at an existing folder and keeps every file where it is.
  /// This never moves, copies or deletes media; it only switches the root and
  /// refreshes the gallery.
  Future<bool> adoptExistingLibrary(
    String path, {
    ValueNotifier<String?>? error,
  }) async {
    final rootPath = p.normalize(path);
    final dir = Directory(rootPath);
    if (!await dir.exists()) {
      error?.value = 'source_missing';
      return false;
    }

    final hidden = _isHiddenPath(rootPath);
    if (!hidden && !await ensureStorageAccess()) {
      error?.value = 'storage_permission_needed';
      return false;
    }

    try {
      final visible = prefs.get<bool>(optionLibraryVisibleInGallery) ?? false;
      final nomedia = File(p.join(rootPath, _nomedia));
      if (hidden) {
        await _ensureNomedia(dir);
        await prefs.set<bool>(optionLibraryVisibleInGallery, false);
      } else if (visible) {
        if (await nomedia.exists()) await nomedia.delete();
      } else if (!await nomedia.exists()) {
        await nomedia.create();
      }

      final oldPath = libraryPath;
      await prefs.set<String>(optionLibraryPath, rootPath);
      await prefs.set<String>(
        optionLibraryStorageMode,
        hidden ? libraryStorageHidden : libraryStorageVisible,
      );

      // A hidden root already lives on a volume whose vault folder is
      // `<volume>/QuaX-Re`; a visible folder uses its parent, like the old
      // sibling-QuaXAccount layout.
      if ((prefs.get<String>(optionVaultRoot) ?? '').isEmpty) {
        if (hidden) {
          for (final volume in await availableVolumes()) {
            if (p.equals(volume.hiddenRoot, rootPath)) {
              await prefs.set<String>(optionVaultRoot, volume.vaultRoot);
              break;
            }
          }
        } else {
          await prefs.set<String>(optionVaultRoot, p.dirname(rootPath));
        }
      }

      _invalidateNameIndexAt(oldPath);
      _invalidateNameIndexAt(rootPath);
      update([]);

      if (!hidden && visible) {
        try {
          // The folder can already hold media; index it right away so the
          // switch means what it says on the first run.
          await _storageChannel.invokeMethod('setGalleryVisibility', {
            'path': rootPath,
            'visible': true,
          });
        } on Exception {
          // The folder still works; the switch can retry the scan.
        }
      }

      await refresh();
      return true;
    } on Exception catch (e) {
      error?.value = e.toString();
      return false;
    }
  }

  bool _isHiddenPath(String path) {
    final parts = p.split(path);
    final android = parts.indexOf('Android');
    return android > 0 &&
        parts.length > android + 1 &&
        parts[android + 1] == 'data';
  }

  /// Whether the library is listed by gallery apps: true means the `.nomedia`
  /// marker is gone.
  bool get galleryVisible =>
      prefs.get<bool>(optionLibraryVisibleInGallery) ?? false;

  /// Live toggle for the gallery apps: drops/creates the `.nomedia` marker and
  /// asks Android to rescan the folder, so the videos appear or disappear from
  /// the system gallery without a restart. The files themselves never move.
  Future<bool> setGalleryVisible(bool visible) async {
    final path = libraryPath;
    if (path.isEmpty) return false;
    // MediaStore cannot index Android/data; the switch has no meaning there.
    if (isHidden) return false;

    try {
      final ok =
          await (debugGalleryVisibility?.call(path, visible) ??
              _storageChannel.invokeMethod<bool>('setGalleryVisibility', {
                'path': path,
                'visible': visible,
              }));
      if (ok != true) return false;

      prefs.set<bool>(optionLibraryVisibleInGallery, visible);
      return true;
    } on Exception {
      return false;
    }
  }

  /// Thumbnails already asked about, keyed by file path. The disk cache under
  /// `thumbs/` remembers the answer; this remembers the *call*. Both the gallery
  /// and the local search hand `thumbnailFor` straight to a FutureBuilder, so
  /// without it every rebuild of a tile re-ran the directory lookup, the stat
  /// and the Android call for a path that had not changed.
  // Shared: the gallery builds its own model per screen, and Settings has to
  // invalidate the lookups after it deletes the on-disk cache.
  static final _thumbnailRequests = LruCache<String, Future<String?>>(400);

  /// Drops the remembered lookups after the `thumbs/` directory was wiped.
  static void clearThumbnailCache() => _thumbnailRequests.clear();

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
      final cacheDir =
          debugThumbnailDirectoryOverride ??
          Directory(p.join((await getTemporaryDirectory()).path, 'thumbs'));
      await cacheDir.create(recursive: true);
      // Hash the path relative to the library, not the basename: two nested
      // clips named clip.mp4 used to share one thumbnail and show the wrong
      // frame (and a deleted clip's frame reappeared for a new one).
      final relative = libraryPath.isEmpty
          ? entry.file.path
          : p.relative(entry.file.path, from: libraryPath);
      final cached = File(p.join(cacheDir.path, thumbnailNameFor(relative)));
      if (await cached.exists()) {
        return cached.path;
      }

      final temp = File(atomicTempPathFor(cached));
      try {
        final result = await _storageChannel.invokeMethod<String>(
          'videoThumbnail',
          {'path': entry.file.path, 'outPath': temp.path},
        );
        if (result == null ||
            !await temp.exists() ||
            await temp.length() == 0) {
          throw const FileSystemException('Thumbnail compression failed');
        }
        await moveFileAtomically(temp, cached, preserveModified: false);
        return cached.path;
      } catch (_) {
        try {
          if (await temp.exists()) await temp.delete();
        } catch (_) {
          // A failed frame must not leave a partial thumbnail behind.
        }
        return null;
      }
    } on Exception {
      return null;
    }
  }

  /// Deletes one library file together with its derived state: the thumbnail
  /// on disk and the remembered lookup. Without this a re-import at the same
  /// name reused the deleted clip's frame.
  Future<void> deleteEntry(LibraryEntry entry) async {
    final key = entry.file.path;
    _thumbnailRequests.remove(key);
    try {
      final cacheDir =
          debugThumbnailDirectoryOverride ??
          Directory(p.join((await getTemporaryDirectory()).path, 'thumbs'));
      final relative = libraryPath.isEmpty
          ? key
          : p.relative(key, from: libraryPath);
      final thumb = File(p.join(cacheDir.path, thumbnailNameFor(relative)));
      if (await thumb.exists()) await thumb.delete();
    } catch (_) {
      // The frame may never have been generated.
    }
    try {
      await entry.file.delete();
      await _forgetLocalMedia(entry.file.path);
    } catch (_) {
      // Already gone: the refresh settles the list either way.
    }
  }

  /// Opens a library file through the system player/viewer. No in-app player:
  /// the file URI is granted to the chosen app directly, so the folder stays
  /// hidden from the gallery while clips play like any other media file.
  Future<bool> openExternally(String path) => openSavedMedia(path: path);

  Future<bool> openSavedMedia({String? path, String? uri}) async {
    final reference = path ?? uri ?? '';
    final mime =
        _mimeTypes[p.extension(reference.split('?').first).toLowerCase()] ??
        '*/*';
    try {
      final ok = await _storageChannel.invokeMethod<bool>('openMediaLocation', {
        'path': path,
        'uri': uri,
        'mime': mime,
      });
      return ok == true;
    } on Exception {
      return false;
    }
  }

  /// The library file matching an exact media URL. Old installs are migrated
  /// from filename matching once; ambiguous stem matches are never guessed.
  Future<String?> localPathFor(String url) async {
    if (libraryPath.isEmpty || url.isEmpty) return null;
    final mapping = await _loadMediaMapping(libraryPath);
    if (mapping.containsKey(url)) {
      final path = mapping[url]!;
      return await File(path).exists() ? path : null;
    }

    final name = p.basename(url.split('?').first);
    if (name.isEmpty) return null;
    final direct = File(p.join(libraryPath, name));
    if (await direct.exists()) {
      await registerLocalMedia(url, direct.path);
      return direct.path;
    }

    await _buildNameIndexIfStale();
    final index = _nameIndexes[libraryPath] ?? const <String, List<String>>{};
    final exact = index[name];
    final directCandidate = p.join(libraryPath, name);
    if (exact != null && exact.contains(directCandidate)) {
      await registerLocalMedia(url, directCandidate);
      return directCandidate;
    }
    final candidates = <String>{};
    if (exact != null) candidates.addAll(exact);
    final stem = p.basenameWithoutExtension(name).toLowerCase();
    final extension = p.extension(name).toLowerCase();
    for (final entry in index.entries) {
      if (p.extension(entry.key).toLowerCase() != extension) continue;
      final keyStem = p.basenameWithoutExtension(entry.key).toLowerCase();
      if (keyStem == stem ||
          keyStem.endsWith('-$stem') ||
          keyStem.contains('-$stem-') ||
          keyStem.startsWith('$stem-')) {
        candidates.addAll(entry.value);
      }
    }
    final existing = candidates
        .where((path) => File(path).existsSync())
        .toList();
    if (existing.length != 1) return null;
    await registerLocalMedia(url, existing.single);
    return existing.single;
  }

  static final Map<String, Map<String, String>> _mediaMappings = {};
  static final Map<String, Future<void>> _mediaMappingLoads = {};
  static final Map<String, Future<void>> _mediaMappingWrites = {};

  Future<Map<String, String>> _loadMediaMapping(String root) async {
    final cached = _mediaMappings[root];
    if (cached != null) return cached;
    final loading = _mediaMappingLoads[root];
    if (loading != null) {
      await loading;
      return _mediaMappings[root] ?? {};
    }

    final future = _readMediaMapping(root);
    _mediaMappingLoads[root] = future;
    try {
      await future;
    } finally {
      if (identical(_mediaMappingLoads[root], future)) {
        _mediaMappingLoads.remove(root);
      }
    }
    return _mediaMappings[root] ?? {};
  }

  Future<void> _readMediaMapping(String root) async {
    final mapping = <String, String>{};
    try {
      final file = File(p.join(root, _mediaLedger));
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        final entries = decoded is Map<String, dynamic>
            ? decoded['entries']
            : null;
        if (entries is List) {
          for (final raw in entries) {
            try {
              if (raw is! Map<String, dynamic>) continue;
              final url = raw['url'] as String?;
              final path = raw['path'] as String?;
              if (url != null &&
                  url.isNotEmpty &&
                  path != null &&
                  p.isAbsolute(path) &&
                  !path.contains('://') &&
                  !path.startsWith('/document/')) {
                mapping[url] = path;
              }
            } catch (_) {
              // Keep the valid mappings around a damaged row.
            }
          }
        }
      }
    } catch (_) {
      // A missing or broken ledger falls back to legacy discovery.
    }
    _mediaMappings[root] = mapping;
  }

  /// Persists the exact URL that produced a downloaded library file.
  Future<bool> registerLocalMedia(String url, String path) async {
    final root = libraryPath;
    if (root.isEmpty || url.isEmpty || !p.isWithin(root, p.normalize(path))) {
      return false;
    }
    if (!await File(path).exists()) return false;
    final mapping = await _loadMediaMapping(root);
    final previous = _mediaMappingWrites[root];
    final completer = Completer<void>();
    _mediaMappingWrites[root] = completer.future;
    if (previous != null) await previous;
    final old = mapping[url];
    mapping[url] = p.normalize(path);
    try {
      await writeAtomically(
        File(p.join(root, _mediaLedger)),
        jsonEncode({
          'version': 1,
          'entries': [
            for (final entry in mapping.entries)
              {'url': entry.key, 'path': entry.value},
          ],
        }),
      );
      return true;
    } catch (_) {
      if (old == null) {
        mapping.remove(url);
      } else {
        mapping[url] = old;
      }
      return false;
    } finally {
      if (identical(_mediaMappingWrites[root], completer.future)) {
        _mediaMappingWrites.remove(root);
      }
      completer.complete();
    }
  }

  Future<void> _mergeMediaMapping(
    String oldRoot,
    String newRoot,
    Map<String, String> inherited,
    Map<String, String> relocatedPaths,
  ) async {
    final ledger = File(p.join(newRoot, _mediaLedger));
    final mapping = await _loadMediaMapping(newRoot);
    if (inherited.isEmpty && !await ledger.exists()) {
      _mediaMappings.remove(oldRoot);
      return;
    }
    for (final entry in inherited.entries) {
      final oldPath = p.normalize(entry.value);
      final moved = relocatedPaths[oldPath];
      if (moved != null) {
        mapping[entry.key] = moved;
      } else if (p.isWithin(oldRoot, oldPath)) {
        // A failed move stays on the old volume. Do not let a pre-existing
        // target file masquerade as the moved bytes.
        mapping[entry.key] = oldPath;
      }
    }
    await writeAtomically(
      File(p.join(newRoot, _mediaLedger)),
      jsonEncode({
        'version': 1,
        'entries': [
          for (final entry in mapping.entries)
            {'url': entry.key, 'path': entry.value},
        ],
      }),
    );
    _mediaMappings.remove(oldRoot);
  }

  Future<void> _forgetLocalMedia(String path) async {
    final root = libraryPath;
    if (root.isEmpty) return;
    final mapping = await _loadMediaMapping(root);
    final matches = mapping.entries
        .where((entry) => p.equals(entry.value, path))
        .toList();
    for (final entry in matches) {
      mapping.remove(entry.key);
    }
    if (matches.isNotEmpty) {
      await writeAtomically(
        File(p.join(root, _mediaLedger)),
        jsonEncode({
          'version': 1,
          'entries': [
            for (final entry in mapping.entries)
              {'url': entry.key, 'path': entry.value},
          ],
        }),
      );
    }
  }

  // The name index is shared by every LibraryModel for the same folder: the
  // video player builds a fresh model per tile, so a per-instance index meant
  // a full recursive scan every time a clip came into view.
  static final Map<String, Map<String, List<String>>> _nameIndexes = {};
  static final Map<String, DateTime> _nameIndexBuiltAt = {};
  static final Map<String, Future<void>> _nameIndexBuilding = {};
  static final Map<String, int> _nameIndexGenerations = {};

  @visibleForTesting
  static Future<void> Function(String path)? debugNameIndexScanHook;

  Future<void> _buildNameIndexIfStale() async {
    final path = libraryPath;
    if (path.isEmpty) return;

    while (true) {
      final builtAt = _nameIndexBuiltAt[path];
      if (builtAt != null && DateTime.now().difference(builtAt).inMinutes < 5) {
        return;
      }

      final building = _nameIndexBuilding[path];
      if (building != null) {
        if (builtAt != null) return;
        await building;
        continue;
      }

      final generation = _nameIndexGenerations[path] ?? 0;
      final index = _nameIndexes[path] ??= {};
      final future = _scanNames(path, index, generation);
      _nameIndexBuilding[path] = future;

      if (builtAt == null) {
        try {
          await future;
        } finally {
          if (identical(_nameIndexBuilding[path], future)) {
            _nameIndexBuilding.remove(path);
          }
        }
        if ((_nameIndexGenerations[path] ?? 0) != generation) continue;
      } else {
        future.whenComplete(() {
          if (identical(_nameIndexBuilding[path], future)) {
            _nameIndexBuilding.remove(path);
          }
        });
      }
      return;
    }
  }

  @visibleForTesting
  static int debugNameIndexBuilds = 0;

  Future<void> _scanNames(
    String path,
    Map<String, List<String>> index,
    int generation,
  ) async {
    debugNameIndexBuilds++;
    final scanned = <String, List<String>>{};
    try {
      final dir = Directory(path);
      if (await dir.exists()) {
        await for (final entity in dir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          (scanned[name] ??= []).add(entity.path);
        }
      }
    } catch (_) {
      // An unreadable folder simply yields no local matches.
    }

    await debugNameIndexScanHook?.call(path);
    if ((_nameIndexGenerations[path] ?? 0) != generation) return;
    index
      ..clear()
      ..addAll(scanned);
    _nameIndexBuiltAt[path] = DateTime.now();
  }

  /// Drops the shared index after the folder's contents changed.
  void _invalidateNameIndex() => _invalidateNameIndexAt(libraryPath);

  void _invalidateNameIndexAt(String path) {
    if (path.isEmpty) return;
    _nameIndexGenerations[path] = (_nameIndexGenerations[path] ?? 0) + 1;
    _nameIndexes.remove(path);
    _nameIndexBuiltAt.remove(path);
  }

  /// Configures the library into the app-private directory of [volume]. No
  /// storage permission is involved: the app owns this tree, and Android keeps
  /// it away from other apps on 11+.
  Future<bool> setupHiddenLibrary(
    LibraryVolume volume, {
    ValueNotifier<String?>? error,
  }) async {
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
    final result = await _moveRoot(
      Directory(volume.hiddenRoot),
      mode: LibraryStorageMode.hidden,
    );
    if (result.error == null) await _pinVaultRoot(volume);
    return result;
  }

  /// Moves the current media into the picked folder (or its `QuaXLibrary`
  /// child) and switches to the visible mode. The vault root deliberately stays
  /// where it is: account backups must not follow a media folder into
  /// app-private storage.
  Future<LibraryMoveResult> moveToVisibleAt(String pickedFolder) {
    return _moveRoot(
      Directory(libraryRootForPickedFolder(pickedFolder)),
      mode: LibraryStorageMode.visible,
    );
  }

  Future<void> _pinVaultRoot(LibraryVolume volume) async {
    final current = prefs.get<String>(optionVaultRoot) ?? '';
    if (current.isNotEmpty) return;
    await prefs.set<String>(optionVaultRoot, volume.vaultRoot);
  }

  Future<LibraryMoveResult> _moveRoot(
    Directory target, {
    required LibraryStorageMode mode,
  }) async {
    await DownloadsModel().pauseAll();
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
    if (p.isWithin(sourcePath, target.path) ||
        p.isWithin(target.path, sourcePath)) {
      return const LibraryMoveResult.failed('inside_library');
    }

    final source = Directory(sourcePath);
    if (!await source.exists()) {
      // A missing source is an ejected SD card, not "nothing to move".
      return const LibraryMoveResult.failed('source_missing');
    }

    final sourceMapping = await _loadMediaMapping(sourcePath);
    // Collect first: moving entries out of a directory while its lazy listing
    // is still walking it can skip files. Sum every file that will actually
    // move, not only media rows from a possibly stale gallery scan.
    final files = <({File file, int size})>[];
    try {
      await for (final entity in source.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File ||
            p.basename(entity.path) == _nomedia ||
            p.relative(entity.path, from: sourcePath) == _mediaLedger) {
          continue;
        }
        var size = 0;
        try {
          size = await entity.length();
        } catch (_) {
          // The move will report this file as failed.
        }
        files.add((file: entity, size: size));
      }
    } catch (e) {
      return LibraryMoveResult.failed(e.toString());
    }
    final totalBytes = files.fold<int>(0, (sum, entry) => sum + entry.size);
    if (!_sameStorage(sourcePath, target.path)) {
      final free = await _availableSpace(target.path);
      if (free != null && totalBytes + _spaceMarginBytes > free) {
        return const LibraryMoveResult.failed('no_space');
      }
    }

    try {
      await target.create(recursive: true);
    } catch (e) {
      return LibraryMoveResult.failed(e.toString());
    }

    var moved = 0;
    final failedFiles = <String>[];
    final movedPaths = <String>[];
    final relocatedPaths = <String, String>{};
    for (final entry in files) {
      try {
        final relative = p.relative(entry.file.path, from: sourcePath);
        var destination = p.join(target.path, relative);
        await Directory(p.dirname(destination)).create(recursive: true);
        if (await File(destination).exists()) {
          destination = _uniqueDestination(destination);
        }
        await moveFileAtomically(
          entry.file,
          File(destination),
          expectedLength: entry.size,
        );
        movedPaths.add(destination);
        relocatedPaths[p.normalize(entry.file.path)] = p.normalize(destination);
        moved++;
      } catch (_) {
        failedFiles.add(entry.file.path);
      }
    }

    try {
      await _configureTarget(
        target,
        mode,
        inheritedMapping: sourceMapping,
        relocatedPaths: relocatedPaths,
      );
    } catch (e) {
      return LibraryMoveResult(
        moved: moved,
        failed: failedFiles.length,
        oldRoot: sourcePath,
        failedFiles: failedFiles,
        relocatedPaths: relocatedPaths,
        error: e.toString(),
      );
    }

    if (mode == LibraryStorageMode.visible && galleryVisible) {
      for (final path in movedPaths) {
        try {
          await _storageChannel.invokeMethod('scanMediaFile', {'path': path});
        } catch (_) {
          // A moved file remains usable even when MediaStore is unavailable.
        }
      }
    }

    try {
      final sourceLedger = File(p.join(sourcePath, _mediaLedger));
      if (await sourceLedger.exists()) await sourceLedger.delete();
    } catch (_) {
      // The merged ledger is authoritative; a locked old copy is harmless.
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
    return LibraryMoveResult(
      moved: moved,
      failed: failedFiles.length,
      oldRoot: failedFiles.isEmpty ? null : sourcePath,
      failedFiles: failedFiles,
      relocatedPaths: relocatedPaths,
    );
  }

  Future<void> _configureTarget(
    Directory target,
    LibraryStorageMode mode, {
    Map<String, String>? inheritedMapping,
    Map<String, String> relocatedPaths = const {},
  }) async {
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
      mode == LibraryStorageMode.hidden
          ? libraryStorageHidden
          : libraryStorageVisible,
    );
    _invalidateNameIndexAt(oldPath);
    _invalidateNameIndexAt(target.path);
    if (!p.equals(oldPath, target.path) && inheritedMapping != null) {
      await _mergeMediaMapping(
        oldPath,
        target.path,
        inheritedMapping,
        relocatedPaths,
      );
    }
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
    final suffix =
        '${DateTime.now().millisecondsSinceEpoch}-${_collisionSequence++}';
    return p.join(p.dirname(path), '$stem-$suffix$extension');
  }

  Future<int?> _availableSpace(String path) async {
    try {
      return await _storageChannel.invokeMethod<int>('getAvailableSpace', {
        'path': path,
      });
    } on Exception {
      return null;
    }
  }

  /// Asks for the all-files grant the visible mode and exports need. Hidden
  /// storage itself never asks: the app owns its `Android/data` tree.
  Future<bool> ensureStorageAccess() async {
    final debug = debugStorageAccess;
    if (debug != null) return debug();
    try {
      var granted = await _storageChannel.invokeMethod<bool>(
        'hasAllFilesAccess',
      );
      if (granted != true) {
        granted = await _storageChannel.invokeMethod<bool>(
          'requestAllFilesAccess',
        );
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
  Future<LibraryExportResult> exportTo(
    String destinationParent, {
    List<LibraryEntry>? entries,
  }) async {
    final sourcePath = libraryPath;
    if (sourcePath.isEmpty) {
      return const LibraryExportResult.failed('not_configured');
    }

    final selected = entries ?? state;
    if (selected.isEmpty) return const LibraryExportResult.failed('empty');
    if (p.equals(destinationParent, sourcePath) ||
        p.isWithin(sourcePath, destinationParent)) {
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
        if (await File(destination).exists()) {
          destination = _uniqueDestination(destination);
        }
        await copyFileAtomically(
          entry.file,
          File(destination),
          expectedLength: entry.size,
        );
        try {
          await _storageChannel.invokeMethod('scanMediaFile', {
            'path': destination,
          });
        } catch (_) {
          // The exported copy remains valid without a MediaStore row.
        }
        copied++;
      } catch (_) {
        failed++;
      }
    }

    return LibraryExportResult(
      copied: copied,
      failed: failed,
      path: target.path,
    );
  }

  /// Configures [pickedPath] into the visible library root, without running the
  /// system picker (the settings screen picks the folder itself).
  ///
  /// Fails (returns false, [error] filled) when the pick landed on storage the
  /// plain file API cannot write to — most often the SD card without Android's
  /// all-files-access grant (Hentoid solves it with SAF; this fork opens the
  /// all-files-access screen instead of carrying a whole SAF tree).
  Future<bool> setupLibraryAt(
    String pickedPath, {
    ValueNotifier<String?>? error,
  }) {
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

  Future<bool> _configureAt(
    String pickedPath, {
    ValueNotifier<String?>? error,
  }) async {
    try {
      // Android 10 and below answer the request only after the user has chosen
      // in the runtime dialog; Android 11+ opens the all-files screen, and the
      // grant only shows on the next check (activity resume).
      final granted = await ensureStorageAccess();
      if (!granted) {
        error?.value = 'storage_permission_needed';
        return false;
      }

      final root = Directory(libraryRootForPickedFolder(pickedPath));
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
      // Backup folder: the library's parent, exactly where the old
      // sibling-QuaXAccount layout already put it. A pick that already was the
      // QuaXLibrary folder must not put the vault inside the media tree.
      if ((prefs.get<String>(optionVaultRoot) ?? '').isEmpty) {
        await prefs.set<String>(optionVaultRoot, p.dirname(root.path));
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

  /// Counts media files under [sourcePath] - old downloads from before the
  /// library existed, or files another app left in a shared folder. Recursive
  /// because the old layout nests them under `X/QuaXLibrary`.
  Future<int> countImportableIn(String sourcePath) async {
    try {
      final sourceDir = Directory(sourcePath);
      if (!await sourceDir.exists()) return 0;

      var count = 0;
      await for (final entity in sourceDir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !_isMedia(entity.path)) continue;
        // The library may sit inside the folder the reader picked; counting
        // its files would make the import offer its own media back.
        if (p.equals(entity.path, libraryPath) ||
            p.isWithin(libraryPath, entity.path)) {
          continue;
        }
        count++;
      }
      return count;
    } on Exception {
      return 0;
    }
  }

  /// Moves the media files under [sourcePath] into the library - copies each
  /// file, then removes the source (Hentoid's import flow). The file's relative
  /// folder is kept so nested downloads do not collide in the library root.
  Future<bool> importFromDirectory(String sourcePath) async {
    if (libraryPath.isEmpty) return false;

    final sourceDir = Directory(sourcePath);
    if (!await sourceDir.exists()) return false;

    // Importing the library into itself used to rename every file with a
    // timestamp, because every target "already existed".
    if (p.equals(sourcePath, libraryPath) ||
        p.isWithin(libraryPath, sourcePath)) {
      return false;
    }

    final files = <File>[];
    var totalBytes = 0;
    try {
      await for (final entity in sourceDir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !_isMedia(entity.path)) continue;
        // A parent pick such as `X` contains the library itself; importing it
        // would copy every library file into a nested QuaXLibrary folder.
        if (p.equals(entity.path, libraryPath) ||
            p.isWithin(libraryPath, entity.path)) {
          continue;
        }
        files.add(entity);
        try {
          totalBytes += await entity.length();
        } catch (_) {
          // The copy will report the unreadable file.
        }
      }
    } on Exception {
      return false;
    }

    final free = await _availableSpace(libraryPath);
    if (free != null && totalBytes + _spaceMarginBytes > free) return false;

    var allMoved = true;
    try {
      for (final entity in files) {
        try {
          final relative = p.relative(entity.path, from: sourcePath);
          var target = p.join(libraryPath, relative);
          // Keep copies of the same basename alive: prefix with the timestamp.
          if (await File(target).exists()) {
            target = p.join(
              p.dirname(target),
              '${p.basenameWithoutExtension(entity.path)}-${DateTime.now().millisecondsSinceEpoch}'
              '${p.extension(entity.path)}',
            );
          }
          await Directory(p.dirname(target)).create(recursive: true);
          final length = await entity.length();
          await moveFileAtomically(
            entity,
            File(target),
            expectedLength: length,
          );
          if (galleryVisible) {
            try {
              await _storageChannel.invokeMethod('scanMediaFile', {
                'path': target,
              });
            } catch (_) {
              // The imported file remains in the library without a gallery row.
            }
          }
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
    return _imageExtensions.contains(extension) ||
        _videoExtensions.contains(extension);
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
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
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
        entries.add(
          LibraryEntry(entity, isVideo, size: size, modified: modified),
        );
      }

      entries.sort((a, b) => b.modified.compareTo(a.modified));
      return entries;
    });
  }
}
