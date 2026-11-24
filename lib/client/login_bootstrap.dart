import 'dart:convert';

/// Reads the logged-in handle and its numeric user id out of the x.com home
/// page the login WebView lands on. The x-web build exposes both fields in
/// `window.__INITIAL_DATA__`; older builds embed the viewer's user entity in
/// the HTML next to the handle.
///
/// [payload] is either the JSON viewer state or the legacy WebView payload:
/// the handle, `|||`, then a small slice of HTML around the first handle.
({String screenName, String? userId}) parseLoginBootstrap(String payload) {
  if (payload.trimLeft().startsWith('{')) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) return parseLoginIdentity(decoded);
    } on FormatException {
      return (screenName: '', userId: null);
    }
    return (screenName: '', userId: null);
  }

  final separator = payload.indexOf('|||');
  if (separator <= 0) return (screenName: '', userId: null);

  final handle = payload.substring(0, separator);
  final around = payload.substring(separator + 3);
  final id = RegExp(
    '"screen_name":"${RegExp.escape(handle)}","id_str":"(\\d+)"',
  ).firstMatch(around)?.group(1);

  return (screenName: handle, userId: id);
}

/// Reads the viewer identity from X's JSON user state. The x-web bootstrap uses
/// `viewerScreenName`/`viewerId`; older REST-shaped responses use
/// `screen_name` with `id_str` or `rest_id`.
({String screenName, String? userId}) parseLoginIdentity(
  Map<String, dynamic> json,
) {
  final handle = json['screen_name'] ?? json['viewerScreenName'];
  final rawId = json['id_str'] ?? json['rest_id'] ?? json['viewerId'];
  return (
    screenName: handle is String ? handle : '',
    userId: rawId is String ? rawId : (rawId is num ? rawId.toString() : null),
  );
}
