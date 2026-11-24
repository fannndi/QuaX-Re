import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quax/constants.dart';
import 'package:quax/downloads/download_paths.dart';
import 'package:quax/downloads/saved_media.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(quaxMethodChannel, null);
    debugTempDirectoryOverride = null;
  });

  test(
    'Should classify a SAF result as a URI without treating it as a path',
    () {
      final saved = SavedMediaLocation.parse(
        'content://com.android.externalstorage.documents/tree/primary%3AQuaXLibrary/document/primary%3AQuaXLibrary%2Fclip.mp4',
      );

      expect(saved.isUri, isTrue);
      expect(saved.uri, contains('content://'));
      expect(
        saved.path,
        isNull,
        reason: '/document/... is not a filesystem path and must never reach File.exists',
      );
    },
  );

  test(
    'Should reject a legacy /document path instead of treating it as a file',
    () {
      final saved = SavedMediaLocation.parse(
        '/document/primary%3AQuaXLibrary%2Fclip.mp4',
      );

      expect(saved.path, isNull);
      expect(
        saved.uri,
        isNull,
        reason: 'A bare document path has lost its provider authority and cannot be reopened',
      );
    },
  );

  test('Should copy a content URI through native before sharing it', () async {
    final temp = Directory.systemTemp.createTempSync('quax-saf-');
    addTearDown(() => temp.deleteSync(recursive: true));
    debugTempDirectoryOverride = temp;
    const uri =
        'content://com.android.externalstorage.documents/document/primary%3Aclip.mp4';
    messenger.setMockMethodCallHandler(quaxMethodChannel, (call) async {
      expect(call.method, 'copyMediaUriToCache');
      final args = call.arguments as Map;
      expect(args['uri'], uri);
      File(args['outPath'] as String).writeAsBytesSync([1, 2, 3]);
      return args['outPath'];
    });

    final file = await shareableFileForSavedMedia(
      SavedMediaLocation.parse(uri),
    );

    expect(
      file,
      isNotNull,
      reason: 'share_plus receives a cache file, not an Android document URI',
    );
    expect(file!.readAsBytesSync(), [1, 2, 3]);
    expect(p.isWithin(temp.path, file.path), isTrue);
  });

  test('Should remove the cache copy when native URI access fails', () async {
    final temp = Directory.systemTemp.createTempSync('quax-saf-fail-');
    addTearDown(() => temp.deleteSync(recursive: true));
    debugTempDirectoryOverride = temp;
    messenger.setMockMethodCallHandler(quaxMethodChannel, (call) async {
      throw PlatformException(code: 'URI_FAILED');
    });

    final file = await shareableFileForSavedMedia(
      SavedMediaLocation.parse(
        'content://provider/document/primary%3Aclip.mp4',
      ),
    );

    expect(file, isNull);
    expect(
      temp.listSync(),
      isEmpty,
      reason:
          'A failed materialization must not leave an empty share temp behind',
    );
  });
}
