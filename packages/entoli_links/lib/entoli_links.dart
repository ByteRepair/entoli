import "package:app_links/app_links.dart";
import "package:entoli_core/model/link_launcher.dart";
import "package:entoli_core/model/sign_in_page.dart";
import "package:url_launcher/url_launcher.dart";

/// Every `entoli://` link, and every claimed share link: the one that
/// launched the app, then each after.
Stream<Uri> incomingLinks() => AppLinks().uriLinkStream;

/// `url_launcher` under every platform's route out of the app.
class PluginLinkLauncher implements LinkLauncher {
  const PluginLinkLauncher();

  @override
  Future<bool> openExternal(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  @override
  Future<bool> openInAppBrowser(Uri url) =>
      launchUrl(url, mode: LaunchMode.inAppBrowserView);
}

/// The page [PluginLinkLauncher.openInAppBrowser] opened: an
/// SFSafariViewController closes, and a Custom Tab, which nothing outside
/// it may close, stays.
class InAppSignInPages implements SignInPages {
  const InAppSignInPages();

  @override
  Future<void> close() async {
    if (await supportsCloseForLaunchMode(LaunchMode.inAppBrowserView)) {
      await closeInAppWebView();
    }
  }
}
