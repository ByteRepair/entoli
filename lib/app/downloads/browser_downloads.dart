import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/agent_browser.dart";
import "../../domain/download.dart";
import "../../providers.dart";
import "downloads.dart";

/// The one thing [Downloads] holds here: the embedded browser, Helium. It
/// replaces the copy the running browser was started from, so that one is
/// quit first.
class EmbeddedBrowserDownloads extends Downloads<String> {
  static const id = "helium";

  @override
  String idOf(String item) => item;

  @override
  Download? begin(String item) {
    final browser = ref.read(agentBrowserProvider);
    Stream<DownloadProgress> install() async* {
      await browser.close();
      yield* browser.embedded.install();
    }

    return Download(bytes: 0, progress: install());
  }

  @override
  String nameOf(String item) => "Helium";

  @override
  String get plural => "browsers";

  /// A first download with nothing picked yet is the pick: it is what the
  /// button was pressed for.
  @override
  Future<void> rescan() async {
    final settings = ref.read(appSettingsProvider);
    if (settings.agentBrowser == null &&
        ref.read(agentBrowserProvider).embedded.installedVersion != null) {
      await ref
          .read(appSettingsProvider.notifier)
          .setAgentBrowser(embeddedBrowserId);
    }
  }

  @override
  Future<void> unpick(String item) async {
    await ref.read(agentBrowserProvider).close();
    if (ref.read(appSettingsProvider).agentBrowser == embeddedBrowserId) {
      await ref.read(appSettingsProvider.notifier).setAgentBrowser(null);
    }
  }

  @override
  Future<void> erase(String item) =>
      ref.read(agentBrowserProvider).embedded.remove();
}

final embeddedBrowserDownloadsProvider =
    NotifierProvider<EmbeddedBrowserDownloads, DownloadState>(
      EmbeddedBrowserDownloads.new,
    );
