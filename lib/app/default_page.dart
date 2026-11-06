import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:quax/app/account_prompt.dart';
import 'package:quax/app/onboarding.dart';
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
import 'package:logging/logging.dart';

class DefaultPage extends StatefulWidget {
  const DefaultPage({super.key});

  @override
  State<StatefulWidget> createState() => _DefaultPageState();
}

class _DefaultPageState extends State<DefaultPage> {
  static final log = Logger('DefaultPage');

  Object? _migrationError;
  StackTrace? _migrationStackTrace;
  StreamSubscription<Uri>? _sub;

  // First run (no library picked yet) goes through the onboarding wizard.
  bool _setupChecked = false;
  bool _setupDone = false;

  // A link that arrived while the wizard was still up: opening the route then
  // would put it on top of onboarding and skip the storage setup.
  Uri? _pendingLink;

  // The "not logged in" prompt is owned here, not by the app shell: it must
  // wait for the wizard to finish instead of covering the setup steps.
  late final Future<void> _migration;
  bool _accountCheckScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_setupChecked) return;
    _setupChecked = true;

    final path = PrefService.of(context).get<String>(optionLibraryPath);
    _setupDone = path != null && path.isNotEmpty;
    _maybePromptForAccount();
  }

  /// Shows the login prompt once per launch, and only once the app is set up:
  /// the wizard owns the screen until the user finishes it.
  void _maybePromptForAccount() {
    if (_accountCheckScheduled || !_setupDone) return;
    _accountCheckScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // The accounts table only exists after the migrations have run; the
      // migration error screen is the one that reports failures.
      await _migration;
      if (!mounted) return;
      if (_migrationError != null) return;
      await checkForAccounts(context);
    });
  }

  /// What a link the app cannot handle gets: an apology with a way out, either
  /// to the report tracker or — when there is a link to open — to a browser.
  void _showUnableToOpenLink(Uri? link) {
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
              onPressed:  () => openUri(context, 'https://github.com/fannndi/QuaX-Re/issues'),
            ),
            if (link != null)
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
  }

  Future<void> handleInitialLink(Uri link) async {
    if (!_setupDone) {
      _pendingLink = link;
      return;
    }
    try {
      final parsed = await parseUri(link);
      if (!mounted) return;

      switch (parsed) {
        case ProfileUriInfo(screenName: final screenName, profileTabIndex: final tab):
          Navigator.pushNamed(context, routeProfile,
              arguments: ProfileScreenArguments.fromScreenName(screenName, tab));
          return;
        case PostUriInfo(screenName: final screenName, id: final id, photoNumber: final photoNumber):
          // A /photo/N link names the picture to land on; N is 1-based while the
          // media pager counts from 0. Without a number (including an FxEmbed
          // direct link, whose .jpg/.mp4 ending parseUri already stripped) the
          // tweet opens on its first piece of media.
          Navigator.pushNamed(context, routeStatus,
              arguments: StatusScreenArguments(
                id: id,
                username: screenName,
                initialMediaIndex: photoNumber == null || photoNumber < 1 ? 0 : photoNumber - 1,
              ));
          return;
        case UnknownResult():
          _showUnableToOpenLink(link);
          return;
      }
    } catch (e, stackTrace) {
      // parseUri resolves short links over the network, so a dead host or a
      // malformed URL throws from inside this callback — the stream's onError
      // never sees it, and the link would otherwise fail in silence.
      log.warning('Unable to open the link $link', e, stackTrace);
      if (!mounted) return;
      _showUnableToOpenLink(link);
    }
  }

  Future<void> _runMigration() async {
    try {
      await Repository().migrate();
    } catch (e, stackTrace) {
      // catchError on a Future<bool> returned the error object and threw
      // "the error handler must return a value of the future's type", so the
      // failure screen never got a chance to own the failure.
      if (!mounted) return;
      setState(() {
        _migrationError = e;
        _migrationStackTrace = stackTrace;
      });
    }
  }

  @override
  void initState() {
    super.initState();

    // Run the database migrations
    _migration = _runMigration();

    final appLinks = AppLinks();

    // Attach a listener to the stream
    _sub = appLinks.uriLinkStream.listen((link) => handleInitialLink(link), onError: (err, stackTrace) {
      log.warning('Unable to read an incoming link', err, stackTrace);
      if (!mounted) return;
      _showUnableToOpenLink(null);
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

    return _setupDone
        ? const HomeScreen()
        : OnboardingScreen(
            onFinished: () {
              setState(() => _setupDone = true);
              _maybePromptForAccount();
              final pending = _pendingLink;
              _pendingLink = null;
              if (pending != null) unawaited(handleInitialLink(pending));
            });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

