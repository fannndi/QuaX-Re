/// Reads the logged-in handle and its numeric user id out of the x.com home
/// page the login WebView lands on. X embeds the viewer's user entity in the
/// page's bootstrap state right next to the handle, so no profile request is
/// needed to learn the id the Likes endpoint takes as `userId`.
///
/// [payload] is what the WebView returns: the handle, `|||`, then the slice of
/// the page that follows the handle (the window keeps the transfer tiny — the
/// home page itself runs to megabytes).
({String screenName, String? userId}) parseLoginBootstrap(String payload) {
  final separator = payload.indexOf('|||');
  if (separator <= 0) return (screenName: '', userId: null);

  final handle = payload.substring(0, separator);
  final around = payload.substring(separator + 3);
  final id = RegExp('"screen_name":"${RegExp.escape(handle)}","id_str":"(\\d+)"')
      .firstMatch(around)
      ?.group(1);

  return (screenName: handle, userId: id);
}
