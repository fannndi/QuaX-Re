import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quax/constants.dart';
import 'package:quax/client/accounts.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/generated/l10n.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;
import 'package:webview_cookie_manager_plus/webview_cookie_manager_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

class TwitterLoginWebview extends StatefulWidget {
  const TwitterLoginWebview({super.key});

  @override
  State<TwitterLoginWebview> createState() => _TwitterLoginWebviewState();
}

class _TwitterLoginWebviewState extends State<TwitterLoginWebview> {
  static const _channel = MethodChannel('browser_resolver');

  /// One controller for the whole screen. Building it in [build] created a
  /// fresh web view (and a fresh load of the login page) on every rebuild —
  /// opening the keyboard to type the username was enough to wipe the form.
  late final WebViewController _controller;
  late final WebviewCookieManager _cookieManager;
  bool _completing = false;

  @override
  void initState() {
    super.initState();

    _cookieManager = WebviewCookieManager();
    _controller = WebViewController();
    _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    // A real browser user agent: the WebView default carries `; wv`, which
    // X's login flow reacts to — and the previous map.toString() was not a
    // user agent at all.
    _controller.setUserAgent(userAgentHeader['user-agent']!);
    _controller.setNavigationDelegate(NavigationDelegate(
      // "Sign in with Google" opens a popup; the native side hosts it so the
      // opener survives and the flow can hand its token back.
      onPageStarted: (_) => _channel.invokeMethod<void>('enableWebViewPopups'),
      onUrlChange: _onUrlChange,
    ));
    _controller.loadRequest(Uri.https('x.com', 'i/flow/login'));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(L10n.of(context).logging_in_quax),
          content: Text(L10n.of(context).logging_in_quax_information),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(L10n.of(context).ok),
            ),
          ],
        ),
      );
    });
  }

  Future<void> _onUrlChange(UrlChange change) async {
    if (_completing || change.url != 'https://x.com/home') return;
    _completing = true;

    try {
      final cookies = await _cookieManager.getCookies('https://x.com/i/flow/login');

      // The home page embeds the logged-in handle in its bootstrap state; it
      // can arrive a beat after the URL changes, so give it a few tries.
      var screenName = '';
      for (var attempt = 0; attempt < 20 && screenName.isEmpty; attempt++) {
        if (attempt > 0) await Future<void>.delayed(const Duration(milliseconds: 500));
        final raw = await _controller.runJavaScriptReturningResult(
          "document.documentElement.outerHTML.match(/\"screen_name\":\"([^\"]+)\"/)?.[1] ?? '';",
        );
        screenName = raw.toString().replaceAll('"', '');
      }
      if (screenName.isEmpty) {
        _completing = false;
        return; // Leave the web view up; the login may still be settling.
      }

      final csrfToken = RegExp(r'(ct0=(.+?));').firstMatch(cookies.toString())?.group(2);
      if (csrfToken != null) {
        final Map<String, String> authHeader = {
          "Cookie": cookies
              .where((cookie) =>
                  cookie.name == "guest_id" ||
                  cookie.name == "gt" ||
                  cookie.name == "att" ||
                  cookie.name == "auth_token" ||
                  cookie.name == "ct0")
              .map((cookie) => '${cookie.name}=${cookie.value}')
              .join(";"),
          "authorization": bearerToken,
          "x-csrf-token": csrfToken,
        };

        final database = await Repository.writable();
        // Re-logging into the same account must refresh its cookies
        // (the id = csrfToken), not crash on the UNIQUE constraint.
        await database.insert(
          tableAccounts,
          Account(id: csrfToken, screenName: screenName, authHeader: json.encode(authHeader)).toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        // No close(): this is sqflite's shared writable handle, so closing it
        // here would pull it out from under every other writer. It is not
        // closed anywhere else either.

        // A freshly added account becomes the one used everywhere, so the
        // timelines immediately speak for the new login.
        await setActiveAccount(csrfToken);
      }
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      _completing = false;
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 50),
      body: WebViewWidget(controller: _controller),
    );
  }
}
