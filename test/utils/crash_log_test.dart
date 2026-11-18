import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quax/utils/crash_log.dart';

void main() {
  late Directory tempDir;
  late File logFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('quax_crash_log');
    logFile = File('${tempDir.path}/crashes.log');
    CrashLog.overrideFileForTest(logFile);
  });

  tearDown(() async {
    CrashLog.overrideFileForTest(null);
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('Should append every entry in the order they happened', () async {
    CrashLog.record(StateError('first'), StackTrace.current, kind: 'test');
    CrashLog.record(StateError('second'), null, kind: 'test');

    final contents = await CrashLog.read();

    expect(contents.indexOf('first'), lessThan(contents.indexOf('second')),
        reason: 'a later error must not hide the one that came before it');
    expect(contents, contains('[test]'),
        reason: 'the kind is what tells a widget error from a native one');
  });

  test('Should strip query strings so request URLs leak no user data', () async {
    CrashLog.record(
      'GET https://api.x.com/graphql/abc/HomeTimeline?userId=42&q=secret',
      null,
    );

    final contents = await CrashLog.read();

    expect(contents, isNot(contains('userId')), reason: 'the user id is personal data');
    expect(contents, isNot(contains('secret')), reason: 'search terms are personal data');
    expect(contents, contains('HomeTimeline'),
        reason: 'the path must survive so the failing endpoint is still named');
  });

  test('Should rotate instead of growing without bound', () async {
    CrashLog.record('x' * (CrashLog.maxBytes + 1024), null);
    CrashLog.record('the entry after the rotation', null);

    expect(await File('${logFile.path}.1').exists(), isTrue,
        reason: 'the oversized log must move aside, not be appended to');
    expect(await logFile.length(), lessThan(CrashLog.maxBytes),
        reason: 'the live file restarts from the newest entry');
    expect(await CrashLog.read(), contains('the entry after the rotation'),
        reason: 'reading the log must include both the backup and the live file');
  });

  test('Should clear both the live log and its backup', () async {
    CrashLog.record('x' * (CrashLog.maxBytes + 1024), null);
    CrashLog.record('later', null);

    await CrashLog.clear();

    expect(await logFile.exists(), isFalse, reason: 'the live log must be gone');
    expect(await File('${logFile.path}.1').exists(), isFalse,
        reason: 'a delete that leaves the backup still shows the old errors');
    expect((await CrashLog.read()).trim(), isEmpty, reason: 'nothing may be reported after a clear');
  });
}
