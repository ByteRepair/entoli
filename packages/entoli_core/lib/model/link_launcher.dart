/// A URL handed to the platform: what `LinkOpener` leaves the app through,
/// and a page that sends the user to another app's screen. Which schemes may
/// reach it is the caller's to decide.
abstract interface class LinkLauncher {
  /// Opens [url] in the app the platform has for its scheme. False where
  /// nothing took it.
  Future<bool> openExternal(Uri url);

  /// Opens [url] in the system's in-app browser — SFSafariViewController, a
  /// Custom Tab — so the app stays in the foreground. False where nothing
  /// took it.
  Future<bool> openInAppBrowser(Uri url);
}
