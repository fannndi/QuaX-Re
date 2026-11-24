import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Should keep the custom native method-channel contract in parity', () {
    final dart = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.readAsStringSync())
        .join('\n');
    final kotlin = Directory('android/app/src/main/kotlin')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.kt'))
        .map((file) => file.readAsStringSync())
        .join('\n');

    const dartToKotlin = [
      'requestNotificationsPermission',
      'startDownloadNotification',
      'downloadNotification',
      'stopDownloadNotification',
      'setRecentsSecure',
      'getDefaultBrowser',
      'hasAllFilesAccess',
      'requestAllFilesAccess',
      'openAppSettings',
      'setGalleryVisibility',
      'isMetered',
      'getAvailableSpace',
      'isSameStorageVolume',
      'openMediaLocation',
      'videoThumbnail',
      'scanMediaFile',
      'saveMediaFile',
      'copyMediaUriToCache',
      'encryptSession',
      'decryptSession',
      'enableWebViewPopups',
    ];
    const kotlinToDart = [
      'onDownloadAction',
      'onDownloadServiceReady',
      'onDownloadServiceFailed',
    ];

    bool mentions(String source, String method) =>
        source.contains("'$method'") || source.contains('"$method"');

    for (final method in dartToKotlin) {
      expect(
        mentions(dart, method),
        isTrue,
        reason: 'Dart no longer calls native method $method',
      );
      expect(
        mentions(kotlin, method),
        isTrue,
        reason: 'Kotlin no longer handles native method $method',
      );
    }
    for (final method in kotlinToDart) {
      expect(
        mentions(dart, method),
        isTrue,
        reason: 'Dart no longer receives native callback $method',
      );
      expect(
        mentions(kotlin, method),
        isTrue,
        reason: 'Kotlin no longer sends native callback $method',
      );
    }
  });
}
