import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/utils/urls.dart';

/// This fork's own releases — asking upstream's repo would offer to "update"
/// the user onto a different codebase.
const _releasesUrl = 'https://api.github.com/repos/fannndi/QuaX-Re/releases/latest';
const _releasesPage = 'https://github.com/fannndi/QuaX-Re/releases';

/// Runs once at startup when the user turned updates on. Anything that goes
/// wrong here — no network, a proxy answering HTML, GitHub rate-limiting — is
/// logged and swallowed: an unhandled async error at startup has no UI to
/// reach, and none of it is worth telling the user about.
Future<void> checkForUpdates(BuildContext context) async {
  Logger.root.info('Checking for updates');

  try {
    final packageInfo = await PackageInfo.fromPlatform();
    final client = HttpClient()
      ..userAgent =
          "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36";

    try {
      final request = await client.getUrl(Uri.parse(_releasesUrl));
      final response = await request.close();
      if (response.statusCode != 200) return;

      final body = json.decode(await utf8.decodeStream(response));
      if (body is! Map<String, dynamic>) return;

      final tag = body['tag_name'] as String?;
      if (tag == null || tag == 'v${packageInfo.version}') return;

      final htmlUrl = (body['html_url'] as String?) ?? _releasesPage;
      if (!context.mounted) return;

      await showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: Text(L10n.of(context).an_update_for_fritter_is_available),
            content: Text(L10n.of(context).view_version_on_github(tag)),
            actions: [
              TextButton(
                child: Text(L10n.of(context).dismiss),
                onPressed: () => Navigator.of(context).pop(),
              ),
              TextButton(
                child: Text(L10n.of(context).view_on_github),
                onPressed: () async {
                  await openUri(context, htmlUrl);
                  Navigator.of(context).pop();
                },
              ),
            ],
          );
        },
      );
    } finally {
      client.close();
    }
  } catch (e, stackTrace) {
    Logger.root.severe('Unable to check for updates', e, stackTrace);
  }
}
