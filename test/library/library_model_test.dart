import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';
import 'package:quax/library/library_model.dart';

/// The import is the one destructive thing the library does: it copies a file
/// out of the reader's folder and then deletes the original. Getting that order
/// wrong, or deleting after a copy that failed, destroys media that exists in
/// one place only — which is exactly what these tests hold it to.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory source;
  late Directory library;

  setUp(() async {
    source = await Directory.systemTemp.createTemp('quax-import-source-');
    library = await Directory.systemTemp.createTemp('quax-import-library-');
    LibraryModel.debugNameIndexBuilds = 0;
  });

  tearDown(() async {
    for (final dir in [source, library]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  LibraryModel modelWith({String? configuredPath}) {
    final prefs = PrefServiceCache();
    prefs.put(optionLibraryPath, configuredPath ?? library.path);
    return LibraryModel(prefs);
  }

  Future<void> putInSource(String name, [String contents = 'media']) async {
    await File('${source.path}/$name').writeAsString(contents);
  }

  group('importFromDirectory()', () {
    test('Should move a media file into the library', () async {
      await putInSource('clip.mp4');

      final moved = await modelWith().importFromDirectory(source.path);

      expect(moved, isTrue, reason: 'The import reports success so the screen can confirm it');
      expect(await File('${library.path}/clip.mp4').exists(), isTrue,
          reason: 'The file has to arrive in the library, which is where the app looks for it');
      expect(await File('${source.path}/clip.mp4').exists(), isFalse,
          reason: 'This is a move, not a copy: a file left behind would show up in the reader\'s '
              'folder and in the library at once');
    });

    test('Should leave files that are not media where they are', () async {
      await putInSource('clip.mp4');
      await putInSource('notes.txt', 'not media');

      await modelWith().importFromDirectory(source.path);

      expect(await File('${library.path}/notes.txt').exists(), isFalse,
          reason: 'The library only ever holds media, so importing a text file would put something '
              'the gallery scan and the mime map cannot describe into it');
      expect(await File('${source.path}/notes.txt').exists(), isTrue,
          reason: 'A file the import did not take must stay where the reader put it');
    });

    test('Should keep both when the library already holds that name', () async {
      File('${library.path}/clip.mp4').writeAsStringSync('already here');
      await putInSource('clip.mp4', 'the new one');

      await modelWith().importFromDirectory(source.path);

      final imported = Directory(library.path)
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('clip'))
          .toList();

      expect(imported, hasLength(2),
          reason: 'Overwriting the existing clip would destroy a download the reader already has, '
              'so the new one has to land under a different name');
      expect(imported.map((f) => f.readAsStringSync()), containsAll(['already here', 'the new one']),
          reason: 'Neither copy may be the other one: both files have to survive with their own bytes');
      expect(await File('${source.path}/clip.mp4').exists(), isFalse,
          reason: 'The import still finishes as a move once the copy landed');
    });

    test('Should leave the source alone when the copy fails', () async {
      await putInSource('clip.mp4');
      // Point the library at a file: joining a name onto it yields a path whose
      // parent is not a directory, so every copy throws.
      await putInSource('a-file', 'not a directory');

      final moved = await modelWith(configuredPath: '${library.path}/a-file')
          .importFromDirectory(source.path);

      expect(moved, isFalse,
          reason: 'An import that could not complete must not report success');
      expect(await File('${source.path}/clip.mp4').exists(), isTrue,
          reason: 'This is the whole point of the order: a copy that failed means the only copy is '
              'the original, and deleting it would lose the reader\'s media for good');
    });

    test('Should refuse without a library to import into', () async {
      await putInSource('clip.mp4');

      final moved = await modelWith(configuredPath: '').importFromDirectory(source.path);

      expect(moved, isFalse,
          reason: 'Importing into an unset path would scatter files somewhere the app never looks');
      expect(await File('${source.path}/clip.mp4').exists(), isTrue,
          reason: 'Nothing may be deleted when there is nowhere to put it');
    });

    test('Should refuse a source folder that does not exist', () async {
      final moved = await modelWith().importFromDirectory('${source.path}/missing');

      expect(moved, isFalse,
          reason: 'A folder the reader picked once and that has since gone is not an import');
      expect(modelWith().state, isEmpty, reason: 'And nothing may appear in the library from it');
    });

    test('Should refuse to import the library into itself', () async {
      File('${library.path}/clip.mp4').writeAsStringSync('keep me');
      final nested = Directory('${library.path}/nested')..createSync();
      File('${nested.path}/clip.mp4').writeAsStringSync('keep me too');

      final moved = await modelWith().importFromDirectory(library.path);

      expect(moved, isFalse,
          reason: 'Importing the library into itself used to rename every file with a timestamp');
      expect(File('${library.path}/clip.mp4').readAsStringSync(), 'keep me',
          reason: 'The original file must keep its name and bytes');
      expect(File('${nested.path}/clip.mp4').readAsStringSync(), 'keep me too');
    });
  });

  group('hidden storage', () {
    test('Should stay empty instead of scanning an empty path', () async {
      final model = LibraryModel(PrefServiceCache());

      await model.refresh();

      expect(model.state, isEmpty,
          reason: 'The storage sheet loads before a library exists; an empty path must not be '
              'resolved as the process working directory and walked recursively');
    });

    test('Should configure the hidden root on the chosen volume and pin the vault', () async {
      final volumeRoot = await Directory.systemTemp.createTemp('quax-volume-');
      addTearDown(() => volumeRoot.delete(recursive: true));
      final volume = LibraryVolume(p.join(volumeRoot.path, 'Android', 'data', 'pkg', 'files'));
      final prefs = PrefServiceCache();
      final model = LibraryModel(prefs);

      final ok = await model.setupHiddenLibrary(volume);

      expect(ok, isTrue, reason: 'The app owns this tree, so no storage permission is involved');
      expect(model.libraryPath, volume.hiddenRoot,
          reason: 'The media belongs in the app-specific directory of the chosen volume, which is '
              'what keeps other apps out');
      expect(Directory(model.libraryPath).existsSync(), isTrue);
      expect(File(p.join(model.libraryPath, '.nomedia')).existsSync(), isTrue,
          reason: 'The marker is cheap insurance for scanners that still walk the app directory');
      expect(prefs.get<String>(optionLibraryStorageMode), libraryStorageHidden);
      expect(prefs.get<bool>(optionLibraryVisibleInGallery), isFalse,
          reason: 'A hidden library can never be shown in the gallery');
      expect(prefs.get<String>(optionVaultRoot), volume.vaultRoot,
          reason: 'The encrypted account backup must stay outside Android/data, which is erased on '
              'uninstall');
    });

    test('Should refuse to move the library into itself', () async {
      File('${library.path}/clip.mp4').writeAsStringSync('keep me');
      final prefs = PrefServiceCache()
        ..put(optionLibraryPath, library.path)
        ..put(optionLibraryStorageMode, libraryStorageVisible)
        ..put(optionVaultRoot, source.path);

      final result = await LibraryModel(prefs).moveToVisibleAt(library.path);

      expect(result.error, 'inside_library',
          reason: 'The target folder would be inside the source; walking it while copying would '
              'duplicate files indefinitely and could destroy the library');
      expect(File('${library.path}/clip.mp4').readAsStringSync(), 'keep me',
          reason: 'A refused move must not touch a single file');
    });

    test('Should move every file into hidden storage and keep the old vault root', () async {
      final volumeRoot = await Directory.systemTemp.createTemp('quax-volume-');
      addTearDown(() => volumeRoot.delete(recursive: true));
      final volume = LibraryVolume(p.join(volumeRoot.path, 'Android', 'data', 'pkg', 'files'));
      final nested = Directory('${library.path}/nested')..createSync(recursive: true);
      File('${library.path}/clip.mp4').writeAsStringSync('clip');
      File('${nested.path}/photo.jpg').writeAsStringSync('photo');
      final prefs = PrefServiceCache()
        ..put(optionLibraryPath, library.path)
        ..put(optionLibraryStorageMode, libraryStorageVisible)
        ..put(optionVaultRoot, source.path);
      final model = LibraryModel(prefs);

      final result = await model.moveToHidden(volume);

      expect(result.ok, isTrue);
      expect(result.moved, 2,
          reason: 'Both the top-level clip and the nested photo have to arrive, not just the first');
      expect(File(p.join(volume.hiddenRoot, 'clip.mp4')).readAsStringSync(), 'clip');
      expect(File(p.join(volume.hiddenRoot, 'nested', 'photo.jpg')).readAsStringSync(), 'photo');
      expect(Directory(library.path).existsSync(), isFalse,
          reason: 'The old visible folder is deleted once only .nomedia is left, so the media is not '
              'resident in two places');
      expect(prefs.get<String>(optionLibraryPath), volume.hiddenRoot);
      expect(prefs.get<String>(optionVaultRoot), source.path,
          reason: 'Moving the media must not drag the account backups into app-private storage');
      expect(model.isHidden, isTrue);
    });

    test('Should keep a colliding name instead of overwriting the hidden copy', () async {
      final volumeRoot = await Directory.systemTemp.createTemp('quax-volume-');
      addTearDown(() => volumeRoot.delete(recursive: true));
      final volume = LibraryVolume(p.join(volumeRoot.path, 'Android', 'data', 'pkg', 'files'));
      final hidden = Directory(volume.hiddenRoot)..createSync(recursive: true);
      File('${hidden.path}/clip.mp4').writeAsStringSync('old');
      File('${library.path}/clip.mp4').writeAsStringSync('new');
      final prefs = PrefServiceCache()
        ..put(optionLibraryPath, library.path)
        ..put(optionLibraryStorageMode, libraryStorageVisible)
        ..put(optionVaultRoot, source.path);

      final result = await LibraryModel(prefs).moveToHidden(volume);

      expect(result.ok, isTrue);
      expect(File('${hidden.path}/clip.mp4').readAsStringSync(), 'old',
          reason: 'A file already in the hidden folder is the reader\'s media too');
      final copied = hidden
          .listSync()
          .whereType<File>()
          .where((file) => p.basename(file.path) != 'clip.mp4' && p.basename(file.path) != '.nomedia');
      expect(copied.single.readAsStringSync(), 'new',
          reason: 'The incoming file gets a timestamp suffix instead of deleting one of the two');
    });

    test('Should move hidden media back into a picked visible folder', () async {
      final volumeRoot = await Directory.systemTemp.createTemp('quax-volume-');
      addTearDown(() => volumeRoot.delete(recursive: true));
      final volume = LibraryVolume(p.join(volumeRoot.path, 'Android', 'data', 'pkg', 'files'));
      final hidden = Directory(volume.hiddenRoot)..createSync(recursive: true);
      File('${hidden.path}/clip.mp4').writeAsStringSync('clip');
      final prefs = PrefServiceCache()
        ..put(optionLibraryPath, hidden.path)
        ..put(optionLibraryStorageMode, libraryStorageHidden)
        ..put(optionVaultRoot, source.path);
      final model = LibraryModel(prefs);

      final result = await model.moveToVisibleAt(source.path);

      expect(result.ok, isTrue);
      final visibleFile = File(p.join(source.path, libraryFolderName, 'clip.mp4'));
      expect(visibleFile.readAsStringSync(), 'clip');
      expect(File(p.join(source.path, libraryFolderName, '.nomedia')).existsSync(), isTrue,
          reason: 'The visible mode defaults to hidden from the gallery');
      expect(prefs.get<String>(optionLibraryStorageMode), libraryStorageVisible);
      expect(model.isHidden, isFalse);
    });

    test('Should export hidden media under readable names', () async {
      File('${library.path}/clip.mp4').writeAsStringSync('clip');
      final prefs = PrefServiceCache()
        ..put(optionLibraryPath, library.path)
        ..put(optionLibraryStorageMode, libraryStorageHidden);
      final model = LibraryModel(prefs);
      await model.refresh();
      final exportRoot = await Directory.systemTemp.createTemp('quax-export-');
      addTearDown(() => exportRoot.delete(recursive: true));

      final result = await model.exportTo(exportRoot.path);

      expect(result.ok, isTrue);
      expect(File(p.join(result.path!, 'clip.mp4')).readAsStringSync(), 'clip',
          reason: 'Export is the way out of app-private storage, so the original name has to return');

      final inside = await model.exportTo(library.path);
      expect(inside.error, 'inside_library',
          reason: 'Exporting into the library would make the gallery list every copy as a new '
              'download');
    });
  });

  group('name index', () {
    test('Should share one scan across models and rebuild after refresh', () async {
      final nested = Directory('${library.path}/nested')..createSync();
      File('${nested.path}/clip.mp4').writeAsStringSync('media');

      final first = modelWith();
      expect(await first.localPathFor('https://x.com/clip.mp4'), isNotNull,
          reason: 'The nested clip must be found by basename when the direct path misses');

      expect(LibraryModel.debugNameIndexBuilds, 1,
          reason: 'The first lookup builds the index once');

      final second = modelWith();
      expect(await second.localPathFor('https://x.com/clip.mp4'), isNotNull);
      expect(LibraryModel.debugNameIndexBuilds, 1,
          reason: 'A fresh LibraryModel per video tile must reuse the shared index instead of '
              'recursively listing the whole library on every start');

      await second.refresh();
      expect(await second.localPathFor('https://x.com/clip.mp4'), isNotNull);
      expect(LibraryModel.debugNameIndexBuilds, 2,
          reason: 'refresh() must drop the index so a new download becomes visible immediately');
    });

    test('Should give nested clips with the same basename different thumbnails', () {
      expect(thumbnailNameFor('a/clip.mp4'), isNot(thumbnailNameFor('b/clip.mp4')),
          reason: 'A basename-only cache key showed the first clip\'s frame for every duplicate');
      expect(thumbnailNameFor('a/clip.mp4'), thumbnailNameFor('a/clip.mp4'),
          reason: 'The same path must map to the same cache file on every run');
    });
  });
}
