import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quax/downloads/atomic_copy.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('quax-atomic-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('Should publish a verified copy under the destination name', () async {
    final source = File(p.join(dir.path, 'source.mp4'))
      ..writeAsBytesSync([1, 2, 3, 4]);
    final destination = File(p.join(dir.path, 'saved.mp4'));

    await copyFileAtomically(source, destination);

    expect(destination.readAsBytesSync(), [
      1,
      2,
      3,
      4,
    ], reason: 'The final name appears only after the whole copy has landed');
    expect(
      dir.listSync().whereType<File>().map((file) => p.basename(file.path)),
      isNot(contains(startsWith('saved.mp4.'))),
      reason: 'A failed or completed promotion must not leave a sibling partial behind',
    );
    expect(
      await source.exists(),
      isTrue,
      reason: 'Copying must not consume the source',
    );
  });

  test(
    'Should delete the sibling partial when final promotion fails',
    () async {
      final source = File(p.join(dir.path, 'source.mp4'))
        ..writeAsBytesSync([1, 2, 3]);
      final destination = Directory(p.join(dir.path, 'saved.mp4'))
        ..createSync();

      await expectLater(
        copyFileAtomically(source, File(destination.path)),
        throwsA(isA<FileSystemException>()),
      );

      expect(
        await source.exists(),
        isTrue,
        reason: 'A failed destination write must leave the only complete source untouched',
      );
      expect(
        directoryEntries(dir),
        ['saved.mp4', 'source.mp4'],
        reason: 'The copied sibling temp is not a valid save and must be deleted on failure',
      );
    },
  );

  test(
    'Should reject a copy whose verified length disagrees with the source',
    () async {
      final source = File(p.join(dir.path, 'source.mp4'))
        ..writeAsBytesSync([1, 2, 3]);
      final destination = File(p.join(dir.path, 'saved.mp4'));

      await expectLater(
        copyFileAtomically(source, destination, expectedLength: 4),
        throwsA(isA<FileSystemException>()),
      );

      expect(
        await destination.exists(),
        isFalse,
        reason: 'A short copy must never be published as a finished download',
      );
      expect(directoryEntries(dir), [
        'source.mp4',
      ], reason: 'Length verification failure must clean up the sibling temp');
    },
  );
}

List<String> directoryEntries(Directory dir) =>
    dir.listSync().map((entity) => p.basename(entity.path)).toList()..sort();
