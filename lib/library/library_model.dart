import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'package:flutter_triple/flutter_triple.dart';
import 'package:path/path.dart' as p;
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';

const _nomedia = '.nomedia';
const libraryFolderName = 'QuaXLibrary';

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
  Future<bool> setupLibraryAt(String pickedPath) {
    return _configureAt(pickedPath);
  }

  /// Shows the system picker, creates the hidden subfolder, writes the
  /// `.nomedia` marker and remembers it. Returns false when no folder was
  /// chosen.
  Future<bool> setupLibrary() async {
    final picked = await FilePicker.getDirectoryPath();
    if (picked == null) return false;

    return _configureAt(picked);
  }

  Future<bool> _configureAt(String pickedPath) async {
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
