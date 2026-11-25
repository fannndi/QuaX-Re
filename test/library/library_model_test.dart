import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pref/pref.dart';
import 'package:quax/constants.dart';
import 'package:quax/downloads/downloads_model.dart';
import 'package:quax/library/library_model.dart';
import 'package:quax/library/library_presence.dart';

/// The import is the one destructive thing the library does: it copies a file
/// out of the reader's folder and then deletes the original. Getting that order
/// wrong, or deleting after a copy that failed, destroys media that exists in
/// one place only — which is exactly what these tests hold it to.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory source;
  late Directory library;
  late Directory queueSupport;

  setUp(() async {
    source = await Directory.systemTemp.createTemp('quax-import-source-');
    library = await Directory.systemTemp.createTemp('quax-import-library-');
    queueSupport = await Directory.systemTemp.createTemp('quax-queue-support-');
    DownloadsModel.debugDirectoryOverride = queueSupport;
    LibraryPresence.resetForTesting();
    LibraryModel.debugNameIndexBuilds = 0;
    LibraryModel.debugExternalDirectories = null;
    LibraryModel.debugStorageAccess = null;
    LibraryModel.debugGalleryVisibility = null;
    LibraryModel.debugNameIndexScanHook = null;
    LibraryModel.debugThumbnailDirectoryOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(quaxMethodChannel, null);
  });

  tearDown(() async {
    await DownloadsModel().flush();
    DownloadsModel().resetForTests();
    DownloadsModel.debugDirectoryOverride = null;
    LibraryPresence.resetForTesting();
    LibraryModel.debugExternalDirectories = null;
    LibraryModel.debugStorageAccess = null;
    LibraryModel.debugGalleryVisibility = null;
    LibraryModel.debugNameIndexScanHook = null;
    LibraryModel.debugThumbnailDirectoryOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(quaxMethodChannel, null);
    for (final dir in [source, library, queueSupport]) {
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

      expect(
        moved,
        isTrue,
        reason: 'The import reports success so the screen can confirm it',
      );
      expect(
        await File('${library.path}/clip.mp4').exists(),
        isTrue,
        reason: 'The file has to arrive in the library, which is where the app looks for it',
      );
      expect(
        await File('${source.path}/clip.mp4').exists(),
        isFalse,
        reason:
            'This is a move, not a copy: a file left behind would show up in the reader\'s '
            'folder and in the library at once',
      );
    });

    test('Should leave files that are not media where they are', () async {
      await putInSource('clip.mp4');
      await putInSource('notes.txt', 'not media');

      await modelWith().importFromDirectory(source.path);

      expect(
        await File('${library.path}/notes.txt').exists(),
        isFalse,
        reason:
            'The library only ever holds media, so importing a text file would put something '
            'the gallery scan and the mime map cannot describe into it',
      );
      expect(
        await File('${source.path}/notes.txt').exists(),
        isTrue,
        reason:
            'A file the import did not take must stay where the reader put it',
      );
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

      expect(
        imported,
        hasLength(2),
        reason:
            'Overwriting the existing clip would destroy a download the reader already has, '
            'so the new one has to land under a different name',
      );
      expect(
        imported.map((f) => f.readAsStringSync()),
        containsAll(['already here', 'the new one']),
        reason: 'Neither copy may be the other one: both files have to survive with their own bytes',
      );
      expect(
        await File('${source.path}/clip.mp4').exists(),
        isFalse,
        reason: 'The import still finishes as a move once the copy landed',
      );
    });

    test('Should leave the source alone when the copy fails', () async {
      await putInSource('clip.mp4');
      // Point the library at a file: joining a name onto it yields a path whose
      // parent is not a directory, so every copy throws.
      File('${library.path}/a-file').writeAsStringSync('not a directory');

      final moved = await modelWith(configuredPath: '${library.path}/a-file')
          .importFromDirectory(source.path);

      expect(
        moved,
        isFalse,
        reason: 'An import that could not complete must not report success',
      );
      expect(
        await File('${source.path}/clip.mp4').exists(),
        isTrue,
        reason:
            'This is the whole point of the order: a copy that failed means the only copy is '
            'the original, and deleting it would lose the reader\'s media for good',
      );
    });

    test('Should refuse without a library to import into', () async {
      await putInSource('clip.mp4');

      final moved = await modelWith(configuredPath: '')
          .importFromDirectory(source.path);

      expect(
        moved,
        isFalse,
        reason: 'Importing into an unset path would scatter files somewhere the app never looks',
      );
      expect(
        await File('${source.path}/clip.mp4').exists(),
        isTrue,
        reason: 'Nothing may be deleted when there is nowhere to put it',
      );
    });

    test('Should refuse a source folder that does not exist', () async {
      final moved = await modelWith().importFromDirectory(
        '${source.path}/missing',
      );

      expect(
        moved,
        isFalse,
        reason: 'A folder the reader picked once and that has since gone is not an import',
      );
      expect(
        modelWith().state,
        isEmpty,
        reason: 'And nothing may appear in the library from it',
      );
    });

    test('Should refuse to import the library into itself', () async {
      File('${library.path}/clip.mp4').writeAsStringSync('keep me');
      final nested = Directory('${library.path}/nested')..createSync();
      File('${nested.path}/clip.mp4').writeAsStringSync('keep me too');

      final moved = await modelWith().importFromDirectory(library.path);

      expect(
        moved,
        isFalse,
        reason: 'Importing the library into itself used to rename every file with a timestamp',
      );
      expect(
        File('${library.path}/clip.mp4').readAsStringSync(),
        'keep me',
        reason: 'The original file must keep its name and bytes',
      );
      expect(File('${nested.path}/clip.mp4').readAsStringSync(), 'keep me too');
    });
  });

  group('hidden storage', () {
    test('Should stay empty instead of scanning an empty path', () async {
      final model = LibraryModel(PrefServiceCache());

      await model.refresh();

      expect(
        model.state,
        isEmpty,
        reason:
            'The storage sheet loads before a library exists; an empty path must not be '
            'resolved as the process working directory and walked recursively',
      );
    });

    test(
      'Should configure the hidden root on the chosen volume and pin the vault',
      () async {
        final volumeRoot = await Directory.systemTemp.createTemp(
          'quax-volume-',
        );
        addTearDown(() => volumeRoot.delete(recursive: true));
        final volume = LibraryVolume(
          p.join(volumeRoot.path, 'Android', 'data', 'pkg', 'files'),
        );
        final prefs = PrefServiceCache();
        final model = LibraryModel(prefs);

        final ok = await model.setupHiddenLibrary(volume);

        expect(
          ok,
          isTrue,
          reason:
              'The app owns this tree, so no storage permission is involved',
        );
        expect(
          model.libraryPath,
          volume.hiddenRoot,
          reason:
              'The media belongs in the app-specific directory of the chosen volume, which is '
              'what keeps other apps out',
        );
        expect(Directory(model.libraryPath).existsSync(), isTrue);
        expect(
          File(p.join(model.libraryPath, '.nomedia')).existsSync(),
          isTrue,
          reason: 'The marker is cheap insurance for scanners that still walk the app directory',
        );
        expect(
          prefs.get<String>(optionLibraryStorageMode),
          libraryStorageHidden,
        );
        expect(
          prefs.get<bool>(optionLibraryVisibleInGallery),
          isFalse,
          reason: 'A hidden library can never be shown in the gallery',
        );
        expect(
          prefs.get<String>(optionVaultRoot),
          volume.vaultRoot,
          reason:
              'The encrypted account backup must stay outside Android/data, which is erased on '
              'uninstall',
        );
      },
    );

    test('Should refuse to move the library into itself', () async {
      File('${library.path}/clip.mp4').writeAsStringSync('keep me');
      final prefs = PrefServiceCache()
        ..put(optionLibraryPath, library.path)
        ..put(optionLibraryStorageMode, libraryStorageVisible)
        ..put(optionVaultRoot, source.path);

      final result = await LibraryModel(prefs).moveToVisibleAt(library.path);

      expect(
        result.error,
        'inside_library',
        reason:
            'The target folder would be inside the source; walking it while copying would '
            'duplicate files indefinitely and could destroy the library',
      );
      expect(
        File('${library.path}/clip.mp4').readAsStringSync(),
        'keep me',
        reason: 'A refused move must not touch a single file',
      );
    });

    test(
      'Should move every file into hidden storage and keep the old vault root',
      () async {
        final volumeRoot = await Directory.systemTemp.createTemp(
          'quax-volume-',
        );
        addTearDown(() => volumeRoot.delete(recursive: true));
        final volume = LibraryVolume(
          p.join(volumeRoot.path, 'Android', 'data', 'pkg', 'files'),
        );
        final nested = Directory('${library.path}/nested')
          ..createSync(recursive: true);
        File('${library.path}/clip.mp4').writeAsStringSync('clip');
        File('${nested.path}/photo.jpg').writeAsStringSync('photo');
        final prefs = PrefServiceCache()
          ..put(optionLibraryPath, library.path)
          ..put(optionLibraryStorageMode, libraryStorageVisible)
          ..put(optionVaultRoot, source.path);
        final model = LibraryModel(prefs);

        final result = await model.moveToHidden(volume);

        expect(result.ok, isTrue);
        expect(
          result.moved,
          2,
          reason: 'Both the top-level clip and the nested photo have to arrive, not just the first',
        );
        expect(
          File(p.join(volume.hiddenRoot, 'clip.mp4')).readAsStringSync(),
          'clip',
        );
        expect(
          File(p.join(volume.hiddenRoot, 'nested', 'photo.jpg'))
              .readAsStringSync(),
          'photo',
        );
        expect(
          Directory(library.path).existsSync(),
          isFalse,
          reason:
              'The old visible folder is deleted once only .nomedia is left, so the media is not '
              'resident in two places',
        );
        expect(prefs.get<String>(optionLibraryPath), volume.hiddenRoot);
        expect(
          prefs.get<String>(optionVaultRoot),
          source.path,
          reason: 'Moving the media must not drag the account backups into app-private storage',
        );
        expect(model.isHidden, isTrue);
      },
    );

    test(
      'Should keep a colliding name instead of overwriting the hidden copy',
      () async {
        final volumeRoot = await Directory.systemTemp.createTemp(
          'quax-volume-',
        );
        addTearDown(() => volumeRoot.delete(recursive: true));
        final volume = LibraryVolume(
          p.join(volumeRoot.path, 'Android', 'data', 'pkg', 'files'),
        );
        final hidden = Directory(volume.hiddenRoot)
          ..createSync(recursive: true);
        File('${hidden.path}/clip.mp4').writeAsStringSync('old');
        File('${library.path}/clip.mp4').writeAsStringSync('new');
        final prefs = PrefServiceCache()
          ..put(optionLibraryPath, library.path)
          ..put(optionLibraryStorageMode, libraryStorageVisible)
          ..put(optionVaultRoot, source.path);

        final result = await LibraryModel(prefs).moveToHidden(volume);

        expect(result.ok, isTrue);
        expect(
          File('${hidden.path}/clip.mp4').readAsStringSync(),
          'old',
          reason:
              'A file already in the hidden folder is the reader\'s media too',
        );
        final copied = hidden.listSync().whereType<File>().where(
          (file) =>
              p.basename(file.path) != 'clip.mp4' &&
              p.basename(file.path) != '.nomedia',
        );
        expect(
          copied.single.readAsStringSync(),
          'new',
          reason: 'The incoming file gets a timestamp suffix instead of deleting one of the two',
        );
      },
    );

    test(
      'Should relocate URL and history mappings to the actual colliding name',
      () async {
        final volumeRoot = await Directory.systemTemp.createTemp(
          'quax-volume-',
        );
        addTearDown(() => volumeRoot.delete(recursive: true));
        final volume = LibraryVolume(
          p.join(volumeRoot.path, 'Android', 'data', 'pkg', 'files'),
        );
        final hidden = Directory(volume.hiddenRoot)
          ..createSync(recursive: true);
        File('${hidden.path}/clip.mp4').writeAsStringSync('old');
        final sourceClip = File('${library.path}/clip.mp4')
          ..writeAsStringSync('new');
        const url = 'https://x.com/clip.mp4';
        final prefs = PrefServiceCache()
          ..put(optionLibraryPath, library.path)
          ..put(optionLibraryStorageMode, libraryStorageVisible)
          ..put(optionVaultRoot, source.path);
        final model = LibraryModel(prefs);
        expect(await model.registerLocalMedia(url, sourceClip.path), isTrue);
        final queue = DownloadsModel()..resetForTests();
        queue.register('clip.mp4', url, true);
        await queue.startRunning('clip.mp4');
        queue.markDone('clip.mp4', savedPath: sourceClip.path);
        await queue.flush();

        final result = await model.moveToHidden(volume);
        final copied = hidden.listSync().whereType<File>().firstWhere(
          (file) =>
              p.extension(file.path) == '.mp4' &&
              p.basename(file.path) != 'clip.mp4',
        );
        await queue.relocateSavedPaths(
          library.path,
          hidden.path,
          relocatedPaths: result.relocatedPaths,
        );

        expect(result.ok, isTrue);
        expect(copied.readAsStringSync(), 'new');
        expect(
          await model.localPathFor(url),
          p.normalize(copied.path),
          reason: 'The exact URL must follow the collision-renamed file, not the pre-existing target',
        );
        expect(
          queue.itemFor('clip.mp4')?.savedPath,
          p.normalize(copied.path),
          reason: 'Download history must open the moved bytes rather than the older target file',
        );
      },
    );

    test(
      'Should move hidden media back into a picked visible folder',
      () async {
        final volumeRoot = await Directory.systemTemp.createTemp(
          'quax-volume-',
        );
        addTearDown(() => volumeRoot.delete(recursive: true));
        final volume = LibraryVolume(
          p.join(volumeRoot.path, 'Android', 'data', 'pkg', 'files'),
        );
        final hidden = Directory(volume.hiddenRoot)
          ..createSync(recursive: true);
        File('${hidden.path}/clip.mp4').writeAsStringSync('clip');
        final prefs = PrefServiceCache()
          ..put(optionLibraryPath, hidden.path)
          ..put(optionLibraryStorageMode, libraryStorageHidden)
          ..put(optionVaultRoot, source.path);
        final model = LibraryModel(prefs);

        final result = await model.moveToVisibleAt(source.path);

        expect(result.ok, isTrue);
        final visibleFile = File(
          p.join(source.path, libraryFolderName, 'clip.mp4'),
        );
        expect(visibleFile.readAsStringSync(), 'clip');
        expect(
          File(p.join(source.path, libraryFolderName, '.nomedia')).existsSync(),
          isTrue,
          reason: 'The visible mode defaults to hidden from the gallery',
        );
        expect(
          prefs.get<String>(optionLibraryStorageMode),
          libraryStorageVisible,
        );
        expect(model.isHidden, isFalse);
      },
    );

    test('Should wait for worker quiescence before moving any file', () async {
      final volumeRoot = await Directory.systemTemp.createTemp('quax-volume-');
      final support = await Directory.systemTemp.createTemp('quax-queue-');
      addTearDown(() async {
        DownloadsModel().resetForTests();
        DownloadsModel.debugDirectoryOverride = null;
        await volumeRoot.delete(recursive: true);
        await support.delete(recursive: true);
      });
      DownloadsModel.debugDirectoryOverride = support;
      final queue = DownloadsModel()..resetForTests();
      queue.register('active.mp4', 'https://x/active.mp4', true);
      await queue.startRunning('active.mp4');
      final entered = Completer<void>();
      final release = Completer<void>();
      final worker = queue.runWorker(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final volume = LibraryVolume(
        p.join(volumeRoot.path, 'Android', 'data', 'pkg', 'files'),
      );
      File('${library.path}/clip.mp4').writeAsStringSync('clip');
      final prefs = PrefServiceCache()
        ..put(optionLibraryPath, library.path)
        ..put(optionLibraryStorageMode, libraryStorageVisible)
        ..put(optionVaultRoot, source.path);

      final moving = LibraryModel(prefs).moveToHidden(volume);
      await Future<void>.delayed(Duration.zero);
      expect(
        File(p.join(volume.hiddenRoot, 'clip.mp4')).existsSync(),
        isFalse,
        reason: 'A live worker could otherwise promote into the folder while it is being moved',
      );
      release.complete();
      await worker;
      await moving;
      expect(
        File(p.join(volume.hiddenRoot, 'clip.mp4')).readAsStringSync(),
        'clip',
      );
    });

    test(
      'Should report a partial move and keep failed files in the old root',
      () async {
        final volumeRoot = await Directory.systemTemp.createTemp(
          'quax-volume-',
        );
        addTearDown(() => volumeRoot.delete(recursive: true));
        final volume = LibraryVolume(
          p.join(volumeRoot.path, 'Android', 'data', 'pkg', 'files'),
        );
        Directory(volume.hiddenRoot).createSync(recursive: true);
        Directory(p.join(volume.hiddenRoot, 'blocked.mp4')).createSync();
        final good = File('${library.path}/good.mp4')
          ..writeAsStringSync('good');
        final blocked = File('${library.path}/blocked.mp4')
          ..writeAsStringSync('only copy');
        final prefs = PrefServiceCache()
          ..put(optionLibraryPath, library.path)
          ..put(optionLibraryStorageMode, libraryStorageVisible)
          ..put(optionVaultRoot, source.path);

        final result = await LibraryModel(prefs).moveToHidden(volume);

        expect(result.moved, 1);
        expect(result.failed, 1);
        expect(
          result.oldRoot,
          library.path,
          reason: 'A partial move must report where the failed files remain',
        );
        expect(result.failedFiles, [p.normalize(blocked.path)]);
        expect(
          await blocked.exists(),
          isTrue,
          reason:
              'The only copy of a failed file must remain in the old folder',
        );
        expect(
          File(p.join(volume.hiddenRoot, 'good.mp4')).readAsStringSync(),
          'good',
        );
        expect(await good.exists(), isFalse);
      },
    );

    test(
      'Should merge exact URL mappings when the target already has a ledger',
      () async {
        final volumeRoot = await Directory.systemTemp.createTemp(
          'quax-volume-',
        );
        addTearDown(() => volumeRoot.delete(recursive: true));
        final volume = LibraryVolume(
          p.join(volumeRoot.path, 'Android', 'data', 'pkg', 'files'),
        );
        final hidden = Directory(volume.hiddenRoot)
          ..createSync(recursive: true);
        final existing = File(p.join(hidden.path, 'existing.mp4'))
          ..writeAsStringSync('existing');
        final targetPrefs = PrefServiceCache()
          ..put(optionLibraryPath, hidden.path)
          ..put(optionLibraryStorageMode, libraryStorageHidden);
        expect(
          await LibraryModel(targetPrefs)
              .registerLocalMedia('https://x/existing', existing.path),
          isTrue,
        );
        File('${library.path}/clip.mp4').writeAsStringSync('clip');
        final prefs = PrefServiceCache()
          ..put(optionLibraryPath, library.path)
          ..put(optionLibraryStorageMode, libraryStorageVisible)
          ..put(optionVaultRoot, source.path);
        final sourceModel = LibraryModel(prefs);
        expect(
          await sourceModel.registerLocalMedia(
            'https://x/clip',
            '${library.path}/clip.mp4',
          ),
          isTrue,
        );

        final result = await sourceModel.moveToHidden(volume);

        expect(result.ok, isTrue);
        expect(
          await sourceModel.localPathFor('https://x/clip'),
          p.normalize('${hidden.path}/clip.mp4'),
        );
        expect(
          await sourceModel.localPathFor('https://x/existing'),
          p.normalize(existing.path),
          reason: 'Moving into a populated folder must not discard its exact URL mappings',
        );
      },
    );

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
      expect(
        File(p.join(result.path!, 'clip.mp4')).readAsStringSync(),
        'clip',
        reason: 'Export is the way out of app-private storage, so the original name has to return',
      );

      final inside = await model.exportTo(library.path);
      expect(
        inside.error,
        'inside_library',
        reason:
            'Exporting into the library would make the gallery list every copy as a new '
            'download',
      );
    });
  });

  group('existing library', () {
    test('Should use a picked QuaXLibrary folder as the root, not nest another one', () {
      final pickedRoot = p.join(source.path, 'X', libraryFolderName);

      expect(
        libraryRootForPickedFolder(pickedRoot),
        p.normalize(pickedRoot),
        reason:
            'Selecting the old library folder itself must not create '
            'QuaXLibrary/QuaXLibrary',
      );
      expect(
        libraryRootForPickedFolder(p.join(source.path, 'X')),
        p.join(source.path, 'X', libraryFolderName),
        reason:
            'Selecting the parent still creates the conventional child folder',
      );
    });

    test('Should adopt an existing folder without moving its files', () async {
      final existing = Directory(p.join(source.path, 'X', libraryFolderName))
        ..createSync(recursive: true);
      final clip = File(p.join(existing.path, 'clip.mp4'))
        ..writeAsStringSync('clip');
      final modified = DateTime(2024, 1, 2, 3, 4, 5);
      await clip.setLastModified(modified);
      final prefs = PrefServiceCache()
        ..put(optionLibraryPath, library.path)
        ..put(optionLibraryStorageMode, libraryStorageHidden)
        ..put(optionVaultRoot, source.path);
      LibraryModel.debugStorageAccess = () async => true;
      final model = LibraryModel(prefs);

      final adopted = await model.adoptExistingLibrary(existing.path);

      expect(
        adopted,
        isTrue,
        reason: 'The old folder has to become the library root',
      );
      expect(prefs.get<String>(optionLibraryPath), p.normalize(existing.path));
      expect(
        prefs.get<String>(optionLibraryStorageMode),
        libraryStorageVisible,
      );
      expect(
        await clip.exists(),
        isTrue,
        reason: 'Adoption keeps the original file in place',
      );
      expect(
        await File(p.join(existing.path, libraryFolderName)).exists(),
        isFalse,
        reason:
            'Adoption must not create a nested QuaXLibrary inside the old root',
      );
      expect(
        model.state.map((entry) => entry.name),
        contains('clip.mp4'),
        reason: 'The gallery must list the adopted folder immediately',
      );
      expect(
        (await clip.lastModified()).difference(modified).inSeconds.abs() < 2,
        isTrue,
        reason:
            'Adoption must not rewrite the mtime the newest sort depends on',
      );
    });

    test(
      'Should only flip the gallery flag when the native pass succeeds',
      () async {
        final prefs = PrefServiceCache()
          ..put(optionLibraryPath, library.path)
          ..put(optionLibraryStorageMode, libraryStorageVisible);
        final model = LibraryModel(prefs);
        LibraryModel.debugGalleryVisibility = (path, visible) async => true;

        expect(await model.setGalleryVisible(true), isTrue);
        expect(
          model.galleryVisible,
          isTrue,
          reason: 'A successful pass must leave the switch showing the folder as visible',
        );

        LibraryModel.debugGalleryVisibility = (path, visible) async => false;
        expect(await model.setGalleryVisible(false), isFalse);
        expect(
          model.galleryVisible,
          isTrue,
          reason: 'A failed pass must not claim the folder was hidden',
        );
      },
    );

    test('Should refuse the gallery switch for hidden storage', () async {
      final prefs = PrefServiceCache()
        ..put(optionLibraryPath, library.path)
        ..put(optionLibraryStorageMode, libraryStorageHidden);
      final model = LibraryModel(prefs);
      var called = false;
      LibraryModel.debugGalleryVisibility = (path, visible) async {
        called = true;
        return true;
      };

      expect(
        await model.setGalleryVisible(true),
        isFalse,
        reason: 'Android/data cannot be indexed by gallery apps',
      );
      expect(
        called,
        isFalse,
        reason: 'The native pass must not run for a hidden root',
      );
    });

    test('Should find an old X/QuaXLibrary under a volume root', () async {
      final appFiles = p.join(source.path, 'Android', 'data', 'pkg', 'files');
      final oldLibrary = Directory(p.join(source.path, 'X', libraryFolderName))
        ..createSync(recursive: true);
      File(p.join(oldLibrary.path, 'clip.mp4')).writeAsStringSync('clip');
      LibraryModel.debugExternalDirectories = () async => [Directory(appFiles)];
      final prefs = PrefServiceCache()
        ..put(optionLibraryPath, library.path)
        ..put(optionLibraryStorageMode, libraryStorageHidden);
      final model = LibraryModel(prefs);

      final found = await model.findExistingLibraries();

      expect(
        found.map((candidate) => candidate.path),
        contains(p.normalize(oldLibrary.path)),
        reason: 'The old SD-card layout is exactly what the reader is trying to reuse',
      );
      final candidate = found.firstWhere(
        (candidate) => candidate.path == p.normalize(oldLibrary.path),
      );
      expect(candidate.mediaCount, 1);
      expect(candidate.isHidden, isFalse);
      expect(candidate.bytes, greaterThan(0));
    });

    test('Should count and import media in subfolders', () async {
      final nested = Directory(p.join(source.path, 'nested'))..createSync();
      final clip = File(p.join(nested.path, 'clip.mp4'))
        ..writeAsStringSync('clip');
      final modified = DateTime(2024, 1, 2, 3, 4, 5);
      await clip.setLastModified(modified);
      final model = modelWith();

      expect(
        await model.countImportableIn(source.path),
        1,
        reason: 'A nested clip is still media the reader can import',
      );

      final moved = await model.importFromDirectory(source.path);

      expect(moved, isTrue);
      final target = File(p.join(library.path, 'nested', 'clip.mp4'));
      expect(
        await target.exists(),
        isTrue,
        reason: 'The import keeps the relative folder so nested clips do not collide',
      );
      expect(
        await clip.exists(),
        isFalse,
        reason: 'The import is still a move',
      );
      expect(
        (await target.lastModified()).difference(modified).inSeconds.abs() < 2,
        isTrue,
        reason:
            'A copy that loses the source mtime breaks the newest/oldest sort',
      );
    });

    test(
      'Should not import the library into itself when its parent is picked',
      () async {
        final root = await Directory.systemTemp.createTemp('quax-parent-');
        addTearDown(() => root.delete(recursive: true));
        final rootLibrary = Directory(p.join(root.path, libraryFolderName))
          ..createSync();
        final clip = File(p.join(rootLibrary.path, 'clip.mp4'))
          ..writeAsStringSync('keep');
        final prefs = PrefServiceCache()
          ..put(optionLibraryPath, rootLibrary.path)
          ..put(optionLibraryStorageMode, libraryStorageVisible);
        final model = LibraryModel(prefs);

        final moved = await model.importFromDirectory(root.path);

        expect(moved, isTrue);
        expect(
          await clip.exists(),
          isTrue,
          reason:
              'The library lives inside the picked parent; importing it would delete the '
              'original',
        );
        expect(
          await File(p.join(rootLibrary.path, libraryFolderName, 'clip.mp4'))
              .exists(),
          isFalse,
          reason: 'A recursive import must not copy the library into a nested QuaXLibrary',
        );
      },
    );
  });

  group('exact URL mapping', () {
    test(
      'Should persist and return distinct paths for colliding URL basenames',
      () async {
        final first = File('${library.path}/first.mp4')
          ..writeAsStringSync('one');
        final second = File('${library.path}/second.mp4')
          ..writeAsStringSync('two');
        final model = modelWith();
        const firstUrl = 'https://video.twimg.com/clip.mp4?tag=1';
        const secondUrl = 'https://video.twimg.com/clip.mp4?tag=2';

        expect(await model.registerLocalMedia(firstUrl, first.path), isTrue);
        expect(await model.registerLocalMedia(secondUrl, second.path), isTrue);

        expect(
          await modelWith().localPathFor(firstUrl),
          p.normalize(first.path),
          reason: 'The exact URL must keep pointing at the first encode',
        );
        expect(
          await modelWith().localPathFor(secondUrl),
          p.normalize(second.path),
          reason: 'A second query variant must not inherit the first file through stem matching',
        );
        final ledger = File('${library.path}/.quax-media.json');
        expect(
          await ledger.exists(),
          isTrue,
          reason: 'The mapping must survive a process restart, not live only in a static index',
        );
        final decoded =
            jsonDecode(await ledger.readAsString()) as Map<String, dynamic>;
        expect((decoded['entries'] as List), hasLength(2));
      },
    );

    test(
      'Should migrate a unique legacy stem match into the exact map',
      () async {
        final legacy = File('${library.path}/reader-clip.mp4')
          ..writeAsStringSync('legacy');
        final model = modelWith();

        expect(
          await model.localPathFor('https://video.twimg.com/clip.mp4?tag=1'),
          p.normalize(legacy.path),
          reason: 'Existing downloads remain playable while their URL mapping is migrated',
        );
        expect(
          await modelWith().localPathFor(
            'https://video.twimg.com/clip.mp4?tag=1',
          ),
          p.normalize(legacy.path),
        );
      },
    );
  });

  group('feed library presence', () {
    test(
      'Should refresh the cached answer after a download and deletion',
      () async {
        final clip = File('${library.path}/clip.jpg')
          ..writeAsStringSync('media');
        final model = modelWith();
        const url = 'https://pbs.twimg.com/media/clip.jpg:orig';

        Future<bool> present() => LibraryPresence.contains(
          root: model.libraryPath,
          url: url,
          lookup: () => model.localPathFor(url),
        );

        expect(
          await present(),
          isFalse,
          reason: 'A media URL that has never been downloaded must not claim gallery presence',
        );
        expect(await model.registerLocalMedia(url, clip.path), isTrue);
        expect(
          await present(),
          isTrue,
          reason:
              'Registering the exact download URL must make the feed badge appear '
              'without a restart',
        );

        await model.deleteEntry(LibraryEntry(clip, false));
        expect(
          await present(),
          isFalse,
          reason:
              'Deleting the file must invalidate the cached true, or the feed '
              'keeps advertising media the gallery no longer has',
        );
      },
    );
  });

  group('name index', () {
    test(
      'Should share one scan across models and rebuild after refresh',
      () async {
        final nested = Directory('${library.path}/nested')..createSync();
        File('${nested.path}/clip.mp4').writeAsStringSync('media');

        final first = modelWith();
        expect(
          await first.localPathFor('https://x.com/clip.mp4'),
          isNotNull,
          reason: 'The nested clip must be found by basename when the direct path misses',
        );

        expect(
          LibraryModel.debugNameIndexBuilds,
          1,
          reason: 'The first lookup builds the index once',
        );

        final second = modelWith();
        expect(
          await second.localPathFor('https://x.com/clip.mp4?tile=2'),
          isNotNull,
        );
        expect(
          LibraryModel.debugNameIndexBuilds,
          1,
          reason:
              'A fresh LibraryModel per video tile must reuse the shared index instead of '
              'recursively listing the whole library on every start',
        );

        await second.refresh();
        expect(
          await second.localPathFor('https://x.com/clip.mp4?tile=3'),
          isNotNull,
        );
        expect(
          LibraryModel.debugNameIndexBuilds,
          2,
          reason: 'refresh() must drop the index so a new download becomes visible immediately',
        );
      },
    );

    test(
      'Should not commit a scan that was invalidated while it was running',
      () async {
        final nested = Directory('${library.path}/nested')..createSync();
        File('${nested.path}/clip.mp4').writeAsStringSync('old');
        final model = modelWith();
        expect(await model.localPathFor('https://x.com/missing.mp4'), isNull);
        await model.refresh();
        final entered = Completer<void>();
        final release = Completer<void>();
        var blockedOnce = false;
        LibraryModel.debugNameIndexScanHook = (path) async {
          if (blockedOnce) return;
          blockedOnce = true;
          entered.complete();
          await release.future;
        };

        final scanning = model.localPathFor('https://x.com/clip.mp4?race=1');
        await entered.future;
        final replacement = File('${library.path}/clip.mp4')
          ..writeAsStringSync('new');
        await model.refresh();
        release.complete();
        final result = await scanning;

        expect(
          result,
          p.normalize(replacement.path),
          reason: 'An invalidated scan must not republish the stale nested path over the new file',
        );
        expect(
          LibraryModel.debugNameIndexBuilds,
          3,
          reason: 'The stale scan is discarded and a fresh generation builds the current index',
        );
      },
    );

    test('Should publish a thumbnail only after native writes a nonempty temp', () async {
      final thumbs = Directory('${source.path}/thumbs');
      LibraryModel.debugThumbnailDirectoryOverride = thumbs;
      final clip = File('${library.path}/clip.mp4')..writeAsStringSync('video');
      final entry = LibraryEntry(clip, true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(quaxMethodChannel, (call) async {
            expect(call.method, 'videoThumbnail');
            final args = call.arguments as Map;
            final outPath = args['outPath'] as String;
            expect(
              outPath.endsWith('.tmp'),
              isTrue,
              reason: 'Native compression must never write directly over a valid cached frame',
            );
            File(outPath).writeAsBytesSync([1, 2, 3]);
            return outPath;
          });

      final path = await modelWith().thumbnailFor(entry);

      expect(path, isNotNull);
      expect(File(path!).readAsBytesSync(), [1, 2, 3]);
      expect(
        thumbs.listSync().whereType<File>().map(
          (file) => p.basename(file.path),
        ),
        [thumbnailNameFor('clip.mp4')],
        reason:
            'The sibling temp is renamed away only after compression succeeds',
      );
    });

    test(
      'Should delete a failed thumbnail partial and allow a retry',
      () async {
        final thumbs = Directory('${source.path}/thumbs');
        LibraryModel.debugThumbnailDirectoryOverride = thumbs;
        final clip = File('${library.path}/clip.mp4')
          ..writeAsStringSync('video');
        final model = modelWith();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(quaxMethodChannel, (call) async {
              final outPath = (call.arguments as Map)['outPath'] as String;
              File(outPath).writeAsBytesSync([1, 2]);
              throw PlatformException(code: 'THUMBNAIL_FAILED');
            });

        expect(await model.thumbnailFor(LibraryEntry(clip, true)), isNull);
        expect(
          thumbs.listSync(),
          isEmpty,
          reason: 'A rejected or failed native thumbnail must not leave a partial frame',
        );

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(quaxMethodChannel, (call) async {
              final outPath = (call.arguments as Map)['outPath'] as String;
              File(outPath).writeAsBytesSync([3, 4]);
              return outPath;
            });
        final retried = await model.thumbnailFor(LibraryEntry(clip, true));
        expect(
          retried,
          isNotNull,
          reason: 'A failed request is evicted from the coalescing cache so the next build can retry',
        );
      },
    );

    test(
      'Should give nested clips with the same basename different thumbnails',
      () {
        expect(
          thumbnailNameFor('a/clip.mp4'),
          isNot(thumbnailNameFor('b/clip.mp4')),
          reason: 'A basename-only cache key showed the first clip\'s frame for every duplicate',
        );
        expect(
          thumbnailNameFor('a/clip.mp4'),
          thumbnailNameFor('a/clip.mp4'),
          reason: 'The same path must map to the same cache file on every run',
        );
      },
    );
  });
}
