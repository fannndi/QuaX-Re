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
  late Directory source;
  late Directory library;

  setUp(() async {
    source = await Directory.systemTemp.createTemp('quax-import-source-');
    library = await Directory.systemTemp.createTemp('quax-import-library-');
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
  });

  group('searchByName()', () {
    setUp(() async {
      await File('${library.path}/beach.mp4').writeAsString('v');
      await File('${library.path}/BEACH DAY.png').writeAsString('i');
      await File('${library.path}/wedding.mov').writeAsString('v');
    });

    test('Should find media whose name contains what was typed', () async {
      final matches = await modelWith().searchByName('beach');

      expect(matches.map((e) => e.file.path).map(p.basename).toList(),
          unorderedEquals(['beach.mp4', 'BEACH DAY.png']),
          reason: 'The Local tab is the only way back to a download the reader cannot otherwise '
              'find, so a name that contains the word has to match');
    });

    test('Should not care how the reader typed the case', () async {
      final lower = await modelWith().searchByName('beach');
      final upper = await modelWith().searchByName('BEACH');

      expect(lower.length, upper.length,
          reason: 'File names keep whatever case the source had, so matching case-sensitively '
              'would hide half the results depending on how the word was typed');
    });

    test('Should return nothing for a word no file carries', () async {
      expect(await modelWith().searchByName('volcano'), isEmpty,
          reason: 'A miss has to read as a miss rather than dumping the whole library');
    });

    test('Should return nothing when there is no library yet', () async {
      expect(await modelWith(configuredPath: '').searchByName('beach'), isEmpty,
          reason: 'Before the folder is set up there is nothing to search, and touching the file '
              'system with an empty path would be a bug in itself');
    });

    test('Should ignore an empty query', () async {
      expect(await modelWith().searchByName('   '), isEmpty,
          reason: 'An empty box is what the screen shows before typing; it must not list everything');
    });
  });
}
