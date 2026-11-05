import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quax/utils/timeline_cache.dart';

void main() {
  test('Should delete thread bodies older than the 30-day shelf', () async {
    final dir = await Directory.systemTemp.createTemp('timeline_cache');
    addTearDown(() => dir.delete(recursive: true));

    final stale = File(p.join(dir.path, 'stale.json'));
    final fresh = File(p.join(dir.path, 'fresh.json'));
    await stale.writeAsString('{}');
    await fresh.writeAsString('{}');
    await stale.setLastModified(DateTime.now().subtract(const Duration(days: 31)));

    await TimelineCache.prune(dir);

    expect(await stale.exists(), isFalse,
        reason: 'A body older than 30 days must leave the disk, not just the in-memory count: '
            'the offline shelf reads every file that is still there');
    expect(await fresh.exists(), isTrue,
        reason: 'A body the reader opened recently is still worth opening offline');
  });
}
