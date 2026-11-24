import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quax/utils/atomic_file.dart';

void main() {
  test(
    'Should leave no temp file when the target cannot be replaced',
    () async {
      final dir = await Directory.systemTemp.createTemp('quax-atomic-failure-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final target = Directory(p.join(dir.path, 'target'));
      await target.create();
      await File(p.join(target.path, 'occupied')).writeAsString('keep');

      await expectLater(
        writeAtomically(File(target.path), 'new content'),
        throwsA(isA<FileSystemException>()),
        reason: 'A directory is not a writable vault file; the failure must reach the caller',
      );

      final leftovers = await dir
          .list()
          .where((entity) => p.basename(entity.path).endsWith('.tmp'))
          .toList();
      expect(
        leftovers,
        isEmpty,
        reason: 'A failed rename must not leave the complete plaintext beside the destination',
      );
      expect(
        await File(p.join(target.path, 'occupied')).exists(),
        isTrue,
        reason: 'Failure cleanup must not delete the existing destination',
      );
    },
  );

  test(
    'Should replace an existing file with the complete new content',
    () async {
      final dir = await Directory.systemTemp.createTemp('quax-atomic-success-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File(p.join(dir.path, 'vault'));
      await file.writeAsString('old');

      await writeAtomically(file, 'new');

      expect(
        await file.readAsString(),
        'new',
        reason: 'A successful atomic write replaces the old file completely',
      );
      expect(
        await dir
            .list()
            .where((entity) => entity.path.endsWith('.tmp'))
            .toList(),
        isEmpty,
        reason:
            'A successful commit leaves no staged copy beside the destination',
      );
    },
  );
}
