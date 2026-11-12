import "dart:io";

import "package:flutter/material.dart";
import "package:url_launcher/url_launcher.dart";

import "../core/log.dart";
import "../core/platform/form_factor.dart";
import "../core/platform/remote_artifact.dart" show RemoteArtifacts;
import "../data/sync/sync_hub.dart";
import "../domain/chat_store.dart";
import "../domain/link_opener.dart";
import "widgets/dialogs.dart";
import "../app/pages/web.dart";
import "app_pages.dart";

/// Web, mail and phone links alone: anything else, `file:` included, would
/// hand the OS whatever scheme a model wrote.
@visibleForTesting
bool isOpenableLink(Uri url) =>
    const {"http", "https", "mailto", "tel"}.contains(url.scheme.toLowerCase());

/// Opens links from rendered markdown, and artifacts the model rendered.
///
/// On Android, `http`/`https` open in an in-app webview so the user stays in
/// the app; other schemes (`mailto:`, `tel:`) fall back to [url_launcher], which
/// a webview cannot load. Everywhere else every URL goes to the external
/// browser via [url_launcher].
///
/// Artifacts open the same way on Android (in-app webview) and desktop (external
/// browser). Android serves the artifact over a local HTTP server because the
/// WebView blocks `file://` URLs on modern Android.
///
/// An artifact of a mirrored chat has no files here — they live on the chat's
/// home device — so the sync hub is asked for the one zip the resource
/// channel carries them over, staged in a temp directory by
/// [RemoteArtifacts], and opened by the same platform path a local
/// artifact takes. The hub is null in tests, which is also the shape of "no
/// sync running": the local paths answer.
class PlatformLinkOpener implements LinkOpener {
  PlatformLinkOpener(this._store, [this._hub])
    : _remote = _hub == null ? null : RemoteArtifacts(_hub);

  final ChatStore _store;

  /// Set in `main`, where the hub is built before the container is. Null
  /// leaves every artifact on the local paths.
  final RemoteArtifacts? _remote;

  /// What the remote arm asks whether this chat is a mirror at all — the
  /// same null in tests that keeps sync-unaware callers on the local paths.
  final SyncHub? _hub;

  /// Where an artifact opens in the app's own webview, served from loopback,
  /// rather than as a `file://` page handed to another app. The phones: iOS
  /// has no app that will open a file inside Entoli's container, so the
  /// desktop route's launch did nothing there at all.
  static bool get _inAppArtifacts => isPhone;

  @override
  Future<void> open(BuildContext context, Uri url) async {
    // Model-written links come through here; artifacts open by their own path.
    if (!isOpenableLink(url)) {
      logFailure("link", "refused a link with scheme ${url.scheme}");
      return;
    }
    if (isAndroid && (url.scheme == "http" || url.scheme == "https")) {
      openAppPage(context, WebAppPage(url));
      return;
    }
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  /// The system's own in-app browser on the phones — SFSafariViewController,
  /// a Custom Tab — rather than the app's webview, which sign-in pages
  /// refuse, or the external browser, which leaves the app in the background.
  @override
  Future<void> openSignIn(BuildContext context, Uri url) async {
    if (url.scheme != "https") {
      logFailure("link", "refused a sign-in page with scheme ${url.scheme}");
      return;
    }
    await launchUrl(
      url,
      mode: isPhone
          ? LaunchMode.inAppBrowserView
          : LaunchMode.externalApplication,
    );
  }

  @override
  Future<void> openArtifact(
    BuildContext context,
    String chatId,
    String artifactId, {
    required String entryFile,
    String? title,
  }) async {
    // A mirrored chat's artifact is fetched from its home device first; the
    // remote arm says which directory it landed in and whether to clean up.
    if (await _remoteArtifact(
      context,
      chatId,
      artifactId,
      entryFile: entryFile,
      title: title,
    )) {
      return;
    }
    final dir = await _store.artifactPath(chatId, artifactId);
    if (!_inAppArtifacts) {
      await _openDesktopArtifact(chatId, artifactId, dir, entryFile);
      return;
    }
    if (!context.mounted) return;
    openAppPage(
      context,
      ArtifactAppPage(dir: dir, entryFile: entryFile, label: title),
    );
  }

  /// The remote arm, where [chatId] is a mirror: fetch the zip, stage it, and
  /// open it by the same viewer a local artifact takes. False is everything
  /// that is not that — no hub, a local chat — and hands the call to the
  /// local paths.
  Future<bool> _remoteArtifact(
    BuildContext context,
    String chatId,
    String artifactId, {
    required String entryFile,
    String? title,
  }) async {
    final remote = _remote;
    if (remote == null || _hub?.mirror(chatId) == null) return false;
    final dir = await remote.fetch(chatId, artifactId, entryFile: entryFile);
    if (dir == null) {
      if (!context.mounted) return true;
      notify(
        context,
        "Could not open the artifact — the device it was "
        "made on is away, or it is no longer there.",
      );
      return true;
    }
    if (!_inAppArtifacts) {
      await launchUrl(
        Uri.file("$dir/$entryFile"),
        mode: LaunchMode.externalApplication,
      );
      return true;
    }
    if (!context.mounted) return true;
    openAppPage(
      context,
      ArtifactAppPage(dir: dir, entryFile: entryFile, label: title),
    );
    return true;
  }

  /// Desktop opens the artifact's entry file itself: the store injects the
  /// base stylesheet into it at publish time, so the file on disk is the
  /// whole page and `file://` resolves its relative references — images,
  /// scripts — against the artifact directory they sit in. Nothing is copied
  /// to a temp location, because the copy would break exactly those paths.
  ///
  /// The remote arm opens out of a staged directory whose entry file the
  /// port has already checked, so it launches straight away instead.
  Future<void> _openDesktopArtifact(
    String chatId,
    String artifactId,
    String dir,
    String entryFile,
  ) async {
    if (!File("$dir/$entryFile").existsSync()) {
      logFailure("open", "Artifact entry file missing: $dir/$entryFile");
      return;
    }
    await launchUrl(
      Uri.file("$dir/$entryFile"),
      mode: LaunchMode.externalApplication,
    );
  }
}

/// The plugin's Android default draws the WebView into a texture Flutter
/// composites, which lags scrolling by a frame and makes flings stutter;
/// hybrid composition puts the native view on screen to scroll by itself.
