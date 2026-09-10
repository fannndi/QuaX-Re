import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'package:quax/constants.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/home/home_screen.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/status.dart';
import 'package:quax/ui/errors.dart';
import 'package:pref/pref.dart';
import 'package:quax/utils/urls.dart';
import 'package:app_links/app_links.dart';

class DefaultPage extends StatefulWidget {
  const DefaultPage({super.key});

  @override
  State<StatefulWidget> createState() => _DefaultPageState();
}

class _DefaultPageState extends State<DefaultPage> {
  Object? _migrationError;
  StackTrace? _migrationStackTrace;
  StreamSubscription<Uri>? _sub;

  void handleInitialLink(Uri link) async {
    final parsed = await parseUri(link);
    switch (parsed) {
      case ProfileUriInfo(screenName: final screenName, profileTabIndex: final tab):
        Navigator.pushNamed(context, routeProfile,
            arguments: ProfileScreenArguments.fromScreenName(screenName, tab));
        return;
      case PostUriInfo(screenName: final screenName, id: final id, direct: final direct, photoNumber: final photoNumber):
        Navigator.pushNamed(context, routeStatus,
            arguments: StatusScreenArguments(
              id: id,
              username: screenName,
            ));
        return;
      case UnknownResult():
        showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              icon: Icon(Icons.error),
              title: Text(L10n.of(context).unable_to_open_link),
              content: Text(L10n.of(context).unable_to_open_link_details),
              actions: [
                TextButton(
                  child: Text(L10n.of(context).report),
                  onPressed:  () => openUri(context, 'https://github.com/teskann/quax/issues'),
                ),
                TextButton(
                  child: Text(L10n.of(context).open_in_browser),
                  onPressed: () {
                    openInDefaultBrowser(link.toString());
                    if(context.mounted) {
                      Navigator.of(context).pop();
                    }
                  },
                ),
              ],
            );
          },
        );

        return;
    }
  }

  @override
  void initState() {
    super.initState();

    // Run the database migrations
    Repository().migrate().catchError((e, s) {
      setState(() {
        _migrationError = e;
        _migrationStackTrace = s;
      });
      return e;
    });

    final appLinks = AppLinks();

    // Attach a listener to the stream
    _sub = appLinks.uriLinkStream.listen((link) => handleInitialLink(link), onError: (err) {
      // TODO: Handle exception by warning the user their action did not succeed
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_migrationError != null || _migrationStackTrace != null) {
      return ScaffoldErrorWidget(
          error: _migrationError,
          stackTrace: _migrationStackTrace,
          prefix: L10n.of(context).unable_to_run_the_database_migrations);
    }

    return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop) return;
          var prefService = PrefService.of(context);
          if (!prefService.get(optionConfirmClose)) {
            SystemNavigator.pop();
            return;
          }

          final confirmed = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text(L10n.current.are_you_sure),
              content: Text(L10n.current.confirm_close_fritter),
              actions: [
                TextButton(
                  child: Text(L10n.current.no),
                  onPressed: () => Navigator.pop(c, false),
                ),
                TextButton(
                  child: Text(L10n.current.yes),
                  onPressed: () => Navigator.pop(c, true),
                ),
              ],
            ),
          );

          if (confirmed == true && context.mounted) {
            SystemNavigator.pop();
          }
        },
        child: const HomeScreen());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

