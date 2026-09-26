import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';
import 'package:quax/utils/lru_cache.dart';

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
  final String name;

  /// [name] folded to lower case once, at construction: the gallery filters and
  /// sorts by it on every keystroke, and folding thousands of names inside the
  /// build path was the single hottest cost of typing in the search field.
  final String nameLower;

  LibraryEntry(this.file, this.isVideo, {this.size = 0, DateTime? modified})
      : name = p.basename(file.path),
        nameLower = p.basename(file.path).toLowerCase(),
        modified = modified ?? DateTime.fromMillisecondsSinceEpoch(0);

  /// Rebuilds an entry from the plain values a worker isolate can send back —
  /// `File` and `DateTime` do not survive the isolate boundary cheaply, so the
  /// scan passes `(path, isVideo, size, modifiedMillis)` instead.
  factory LibraryEntry.fromPrimitives(
      String path, bool isVideo, int size, int modifiedMillis) {
    return LibraryEntry(
      File(path),
      isVideo,
      size: size,
      modified: DateTime.fromMillisecondsSinceEpoch(modifiedMillis),
    );
  }

  double get sizeMb => size / 1048576;
}

/// What a gallery pass reports while it runs, streamed from the native side so
/// the switch can show real progress instead of spinning blind. [done]/[total]
/// count media files already pushed through the scanner; [phase] is one of
/// `scan`, `verify`.
class GalleryProgress {
  const GalleryProgress({required this.done, required this.total, required this.phase});

  final int done;
  final int total;
  final String phase;

  double get fraction => total <= 0 ? 0 : (done / total).clamp(0.0, 1.0).toDouble();

  static GalleryProgress? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final done = (raw['done'] as num?)?.toInt();
    final total = (raw['total'] as num?)?.toInt();
    if (done == null || total == null) return null;

    return GalleryProgress(done: done, total: total, phase: raw['phase'] as String? ?? 'scan');
  }
}

/// Outcome of a gallery show/hide pass: [affected] media files entered (or
/// left) the gallery, [remaining] says how many rows stayed behind in the
/// media database after hiding (0 means fully hidden).
class GalleryVisibilityResult {
  const GalleryVisibilityResult({required this.ok, this.affected = 0, this.remaining = 0});

  static const failed = GalleryVisibilityResult(ok: false);

  /// Another pass was already running: this request was folded into it (the
  /// newest intent wins), so the caller must neither report an outcome nor
  /// treat the toggle as applied.
  static const queued = GalleryVisibilityResult(ok: false);

  final bool ok;
  final int affected;
  final int remaining;
}

/// State of the Hentoid-style hidden library: a folder the user picked from
/// the device storage (visible in file managers), holding every downloaded
/// media and a `.nomedia` marker that keeps gallery apps from indexing it.
class LibraryModel extends Store<List<LibraryEntry>> {
  final BasePrefService prefs;

  LibraryModel(this.prefs) : super([]) {
    _storageChannel.setMethodCallHandler(_onNativeCall);
  }

  /// Latest reported gallery pass, kept so a rebuild mid-pass (the grid
  /// refreshing behind the switch) does not lose the progress bar.
  final ValueNotifier<GalleryProgress?> progress = ValueNotifier(null);

  /// Serializes gallery passes: the native side scans the whole folder, so two
  /// overlapping passes would interleave scans and report nonsense. A pass
  /// asked for while one runs is remembered as [pendingVisible] and replayed
  /// once the first answers — last intent wins, nothing is dropped.
  bool _passRunning = false;
  bool? _pendingVisible;

  String get libraryPath => prefs.get<String>(optionLibraryPath) ?? '';

  bool get isConfigured => libraryPath.isNotEmpty;

  /// Whether the library is listed by gallery apps: true means the `.nomedia`
  /// marker is gone.
  bool get galleryVisible => prefs.get<bool>(optionLibraryVisibleInGallery) ?? false;

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method != 'galleryProgress') return;
    progress.value = GalleryProgress.fromMap(call.arguments);
  }

  /// Live toggle for the gallery apps: drops/creates the `.nomedia` marker and
  /// asks Android to rescan the folder, so the videos appear or disappear from
  /// the system gallery without a restart.
  ///
  /// Passes are serialized (one scan at a time) and the newest request wins;
  /// call [onProgress] to paint the streamed native progress. Prefer
  /// [setGalleryVisibleInBackground] from the switch: it lets the UI flip
  /// optimistically instead of blocking the toggle for the whole scan.
  Future<GalleryVisibilityResult> setGalleryVisible(
    bool visible, {
    void Function(GalleryProgress)? onProgress,
  }) {
    if (onProgress == null) return _runOrQueue(visible, onProgress);

    _progressSinks.add(onProgress);
    // Detach once this pass settles, so a rebuilt screen does not keep feeding
    // a callback whose State is gone.
    return _runOrQueue(visible, onProgress)
        .whenComplete(() => _progressSinks.remove(onProgress));
  }

  final Set<void Function(GalleryProgress)> _progressSinks = {};

  void _emitProgress(GalleryProgress value) {
    progress.value = value;
    for (final sink in List.of(_progressSinks)) {
      try {
        sink(value);
      } catch (_) {
        // A listener throwing must not abort a running native pass.
      }
    }
  }

  Future<GalleryVisibilityResult> _runOrQueue(
      bool visible, void Function(GalleryProgress)? onProgress) async {
    if (_passRunning) {
      _pendingVisible = visible;
      return GalleryVisibilityResult.queued;
    }

    _passRunning = true;
    _emitProgress(const GalleryProgress(done: 0, total: 0, phase: 'scan'));
    try {
      final result = await _applyVisibility(visible, onProgress);

      final next = _pendingVisible;
      _pendingVisible = null;
      if (next != null && next != visible) {
        return _runOrQueue(next, onProgress);
      }
      return result;
    } finally {
      _passRunning = false;
      progress.value = null;
    }
  }

  Future<GalleryVisibilityResult> _applyVisibility(
      bool visible, void Function(GalleryProgress)? onProgress) async {
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

  /// Fire-and-forget flavour of [setGalleryVisible]: returns immediately with
  /// the pass it just started. The caller flips its switch optimistically on
  /// that signal and awaits [onSettled] for the real outcome. A toggle that
  /// arrives while this pass runs is folded into the running pass, so callers
  /// that [queued] must leave their optimistic flip alone until the pass it
  /// joined reports.
  void setGalleryVisibleInBackground(
    bool visible, {
    void Function(GalleryProgress)? onProgress,
    required void Function(GalleryVisibilityResult) onSettled,
  }) {
    const queuedPass = GalleryVisibilityResult.queued;
    final pass = setGalleryVisible(visible, onProgress: onProgress);
    unawaited(pass.then((result) {
      if (identical(result, queuedPass)) return; // the pass it joined reports
      onSettled(result);
    }));
  }

  /// Cached thumbnail of a video, generated once by the Android handler
  /// (MediaMetadataRetriever one second in). Serves both the grid tile and the
  /// viewer's poster, so a downloaded clip never shows as a black frame.
  ///
  /// The *Future* is cached, not just the path: the tile used to call this from
  /// `build()`, so every selection tap re-ran the `cached.exists()` probe and
  /// could flash the placeholder. Bounded, because a library can hold thousands
  /// of clips and each entry is a live Future.
  final LruCache<String, Future<String?>> _thumbnailFutures = LruCache(400);

  Future<String?> thumbnailFor(LibraryEntry entry) {
    final cached = _thumbnailFutures.get(entry.file.path);
    if (cached != null) return cached;

    final future = _resolveThumbnail(entry);
    _thumbnailFutures.set(entry.file.path, future);
    return future;
  }

  Future<String?> _resolveThumbnail(LibraryEntry entry) async {
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

  /// Drops the cached thumbnail Futures. Called after deletions: a cached
  /// entry would otherwise point at a file that is gone, and a later download
  /// reusing the name must resolve fresh.
  void forgetThumbnails() => _thumbnailFutures.clear();

  void dispose() {
    progress.dispose();
    _storageChannel.setMethodCallHandler(null);
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

  /// Library files whose name contains [query]. Downloads are named
  /// `handle-<media id>.ext`, so searching an account finds the media taken
  /// from it without any network request.
  Future<List<LibraryEntry>> searchByName(String query, {int limit = 30}) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty || libraryPath.isEmpty) return const [];

    await _buildNameIndexIfStale();

    final matches = <LibraryEntry>[];
    for (final entry in _localNames.entries) {
      if (!entry.key.toLowerCase().contains(needle)) continue;

      matches.add(LibraryEntry(File(entry.value), _videoExtensions.contains(p.extension(entry.key).toLowerCase())));
      if (matches.length >= limit) break;
    }
    return matches;
  }

  Future<void> _buildNameIndexIfStale() async {
    final now = DateTime.now();
    if (_localNames.isNotEmpty && now.difference(_namesBuiltAt).inMinutes < 5) return;

    _namesBuiltAt = now;
    _localNames.clear();

    final path = libraryPath;
    if (path.isEmpty) return;

    try {
      // A recursive walk of a big folder is tens of milliseconds of pure I/O —
      // enough to drop frames when it lands mid-scroll, so it runs off-thread.
      final found = await Isolate.run(() => _indexFolder(path));
      _localNames.addAll(found);
    } catch (_) {
      // An unreadable folder simply yields no local matches.
    }
  }

  /// Worker-isolate body of [_buildNameIndexIfStale]: basename → full path.
  static Map<String, String> _indexFolder(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return const {};

    final names = <String, String>{};
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is File) names[p.basename(entity.path)] = entity.path;
    }
    return names;
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

  /// Rescans the library folder.
  ///
  /// The walk and the per-file `stat` used to run on the UI isolate — thousands
  /// of synchronous syscalls, each one a dropped frame. They now run in a
  /// worker isolate and come back as plain values, and [Isolate.run] keeps the
  /// UI thread free for the grid that is about to be rebuilt.
  Future<void> refresh() async {
    final path = libraryPath;
    await execute(() => _scanLibrary(path));
  }

  static Future<List<LibraryEntry>> _scanLibrary(String path) async {
    if (path.isEmpty) return const [];

    final raw = await Isolate.run(() => _scanSync(path));
    final entries = raw
        .map((row) => LibraryEntry.fromPrimitives(row[0] as String, row[1] as bool, row[2] as int, row[3] as int))
        .toList();
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    return entries;
  }

  /// Entry point of the worker isolate. Takes and returns only primitives, so
  /// nothing but plain data crosses the isolate boundary.
  static List<List<Object>> _scanSync(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return const [];

    final rows = <List<Object>>[];
    // Recursive: imported libraries (or files the user nested) still show up.
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;

      final extension = p.extension(entity.path).toLowerCase();
      final isVideo = _videoExtensions.contains(extension);
      if (!isVideo && !_imageExtensions.contains(extension)) continue;

      var modified = 0;
      var size = 0;
      try {
        final stat = entity.statSync();
        modified = stat.modified.millisecondsSinceEpoch;
        size = stat.size;
      } catch (_) {
        // Unreadable file: keep it listed with empty metadata.
      }
      rows.add([entity.path, isVideo, size, modified]);
    }
    return rows;
  }
}
