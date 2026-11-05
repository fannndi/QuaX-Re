import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:quax/client/http_client.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/utils/urls.dart';

/// This fork's own releases — asking upstream's repo would offer to "update"
/// the user onto a different codebase.
const _releasesPage = 'https://github.com/fannndi/QuaX-Re/releases';

/// Runs once at startup when the user turned updates on. Anything that goes
/// wrong here — no network, a proxy answering HTML, GitHub rate-limiting — is
/// logged and swallowed: an unhandled async error at startup has no UI to
/// reach, and none of it is worth telling the user about.
Future<void> checkForUpdates(BuildContext context) async {
  Logger.root.info('Checking for updates');

  try {
    final packageInfo = await PackageInfo.fromPlatform();
    final response = await fetchLatestRelease();
    if (response.statusCode != 200) return;

    final body = json.decode(response.body);
    if (body is! Map<String, dynamic>) return;

    final tag = body['tag_name'] as String?;
    if (tag == null || tag == 'v${packageInfo.version}') return;

    final htmlUrl = (body['html_url'] as String?) ?? _releasesPage;
    if (!context.mounted) return;

    await _showUpdateDialog(context, tag, htmlUrl);
  } catch (e, stackTrace) {
    Logger.root.severe('Unable to check for updates', e, stackTrace);
  }
}

/// Asks the reader whether to go and get the release the fetch found: the tag
/// is what the dialog shows, and the link is where the release page lives.
Future<void> _showUpdateDialog(BuildContext context, String tag, String htmlUrl) {
  return showDialog(
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
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ],
      );
    },
  );
}
