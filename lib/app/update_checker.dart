import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/utils/urls.dart';
Future checkForUpdates(context) async {
  Logger.root.info('Checking for updates');

  PackageInfo packageInfo = await PackageInfo.fromPlatform();
  final client = HttpClient();
  client.userAgent =
      "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36";

  final request = await client.getUrl(Uri.parse("https://api.github.com/repos/teskann/quax/releases/latest"));
  final response = await request.close();

  if (response.statusCode == 200) {
    final contentAsString = await utf8.decodeStream(response);
    final Map<dynamic, dynamic> map = json.decode(contentAsString);
    if (map["tag_name"] != null) {
      if (map["tag_name"] != 'v${packageInfo.version}') {
        await showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: Text(L10n.of(context).an_update_for_fritter_is_available),
              content: Text(L10n.of(context).view_version_on_github(map["tag_name"])),
              actions: [
                TextButton(
                  child: Text(L10n.of(context).dismiss),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                TextButton(
                  child: Text(L10n.of(context).view_on_github),
                  onPressed: () async {
                    await openUri(context, map['html_url']);
                    Navigator.of(context).pop();
                  },
                ),
              ],
            );
          },
        );
      } else if (map['html_url'].isEmpty) {
        Logger.root.severe('Unable to check for updates');
      }
    }
  }
}


class UnableToCheckForUpdatesException {
  final String body;

  UnableToCheckForUpdatesException(this.body);

  @override
  String toString() {
    return 'Unable to check for updates: {body: $body}';
  }
}

