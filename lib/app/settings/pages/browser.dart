import "dart:async";

import "package:file_selector/file_selector.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/log.dart";
import "../../../domain/agent_browser.dart";
import "../../../domain/settings/keys.dart";
import "../../../providers.dart";
import "../../downloads/browser_downloads.dart";
import "../bind.dart";
import "../controller.dart";
import "../spec.dart";

const _page = SettingsPageId.agentBrowser;

/// The answer that opens the file picker rather than picking.
const chooseBrowser = "\u0000choose";

/// The browsers this machine has, asked once while settings shows them.
final foundBrowsersProvider = FutureProvider.autoDispose<List<FoundBrowser>>(
  (ref) => ref.watch(agentBrowserProvider).detect(),
);

/// Whether the agent's browser is running now.
final browserRunningProvider = NotifierProvider<BrowserRunning, bool>(
  BrowserRunning.new,
);

class BrowserRunning extends Notifier<bool> with ListenableValue<bool> {
  @override
  bool build() => bridge(ref.watch(agentBrowserProvider).running);
}

/// A browser being picked from the disk: started first, to check it can be
/// driven, and why it could not where it could not.
typedef BrowserPick = ({bool verifying, String? problem});

final browserPickProvider = NotifierProvider<BrowserPicker, BrowserPick>(
  BrowserPicker.new,
);

class BrowserPicker extends Notifier<BrowserPick> {
  @override
  BrowserPick build() => (verifying: false, problem: null);

  Future<void> pick(String? value) async {
    final settings = ref.read(appSettingsProvider.notifier);
    if (value != chooseBrowser) {
      state = (verifying: false, problem: null);
      return settings.setAgentBrowser(value);
    }
    final file = await openFile(confirmButtonText: "Use this browser");
    if (file == null) return;
    state = (verifying: true, problem: null);
    try {
      final exe = await ref.read(agentBrowserProvider).verify(file.path);
      await settings.setAgentBrowser(exe);
      state = (verifying: false, problem: null);
    } catch (e) {
      state = (verifying: false, problem: "$e");
    }
  }
}

final browserSections = [
  const SectionSpec(
    page: _page,
    id: "agentBrowser",
    title: "Agent browser",
    weight: 0,
    description:
        "A browser window the agent opens pages in, clicks and "
        "types into, for pages that need JavaScript or a login. It runs "
        "with a profile of its own, so what it logs into stays logged in "
        "and your own browser's profile is never touched.",
  ),
  SectionSpec(
    page: _page,
    id: "embedded",
    title: "Embedded browser",
    weight: 10,
    description:
        "Helium, a Chromium browser that ships with uBlock "
        "Origin: the pages the agent opens come without ads or "
        "trackers, and with fewer scripts that try to talk it into "
        "something. Downloaded from Helium's GitHub releases.",
    shown: (ref) => !ref.watch(agentBrowserProvider).inApp,
  ),
];

final browserSettings = [
  // The phones' is the app's own WebView: on or off, nothing to pick.
  SettingSpec(
    id: "webViewBrowser",
    path: (page: _page, section: "agentBrowser"),
    weight: 0,
    title: "Let the agent use a browser",
    description:
        "A WebView kept off screen. The chat's "
        "browser card shows its page.",
    hint: UiHint.toggle,
    build: (c) {
      final browser = c.ref.watch(agentBrowserProvider);
      return ToggleController(
        c.spec,
        value: browser.configured,
        effective: browser.configured,
        visible: browser.inApp,
        onSet: (on) async {
          await c.ref
              .read(appSettingsProvider.notifier)
              .setAgentBrowser((on ?? false) ? webViewBrowserId : browserOffId);
          return null;
        },
      );
    },
  ),
  SettingSpec(
    id: "agentBrowser",
    path: (page: _page, section: "agentBrowser"),
    weight: 10,
    title: "Browser",
    hint: UiHint.dropdown,
    build: (c) {
      final browser = c.ref.watch(agentBrowserProvider);
      final found = c.ref.watch(foundBrowsersProvider).value ?? const [];
      final pick = c.ref.watch(browserPickProvider);
      final picked = c.scope.resolve(SettingKeys.agentBrowser);
      final installed = browser.embedded.installedVersion;
      final custom =
          picked != null &&
          picked != embeddedBrowserId &&
          !found.any((b) => b.path == picked);
      final picker = c.ref.read(browserPickProvider.notifier);
      return ChoiceController<String?>(
        c.spec,
        options: [
          const SettingOption(null, "Off"),
          if (installed != null)
            SettingOption(embeddedBrowserId, "Embedded (Helium $installed)"),
          for (final found in found) SettingOption(found.path, found.name),
          if (custom) SettingOption(picked, picked),
          const SettingOption(chooseBrowser, "Choose a browser…"),
        ],
        value: picked == embeddedBrowserId && installed == null ? null : picked,
        description: pick.verifying
            ? "Starting it to check it can be driven…"
            : picked == null
            ? "Off: the agent has no browser tools."
            : "Only Chromium-family browsers can be driven.",
        error: pick.problem,
        enabled: !pick.verifying,
        visible: !browser.inApp,
        onSet: (value) async {
          unawaited(picker.pick(value));
          return null;
        },
      );
    },
  ),
  SettingSpec(
    id: "agentBrowserVisible",
    path: (page: _page, section: "agentBrowser"),
    weight: 20,
    title: "Show the browser window",
    description:
        "Off, it runs hidden. The agent can still "
        "open a window when it needs you to finish a check.",
    hint: UiHint.toggle,
    build: (c) {
      final browser = c.ref.watch(agentBrowserProvider);
      return c.toggle(
        SettingKeys.agentBrowserVisible,
        visible: !browser.inApp,
        // The running one is in the other mode; the next call starts one
        // in this.
        write: (value) async {
          await c.scope.write(SettingKeys.agentBrowserVisible, value);
          await browser.close(
            why:
                "The browser restarted because the user changed "
                "whether it shows a window.",
          );
        },
      );
    },
  ),
  SettingSpec(
    id: "agentBrowserApproval",
    path: (page: _page, section: "agentBrowser"),
    weight: 30,
    title: "Before the agent acts",
    hint: UiHint.dropdown,
    build: (c) => c.choice(
      SettingKeys.agentBrowserApproval,
      const [
        SettingOption(BrowserApproval.never, "Don't ask"),
        SettingOption(BrowserApproval.classifier, "Let the classifier decide"),
        SettingOption(BrowserApproval.always, "Ask every time"),
      ],
      description:
          "Opening a page, clicking, typing and dragging. A "
          "site you have denied in a permission rule stays denied.",
    ),
  ),
  SettingSpec(
    id: "agentBrowserUploads",
    path: (page: _page, section: "agentBrowser"),
    weight: 40,
    title: "File uploads",
    hint: UiHint.dropdown,
    build: (c) => c.choice(
      SettingKeys.agentBrowserUploads,
      const [
        SettingOption(
          BrowserUploadPolicy.classifier,
          "Let the classifier decide",
        ),
        SettingOption(BrowserUploadPolicy.allow, "Don't ask"),
        SettingOption(BrowserUploadPolicy.user, "I choose the file"),
      ],
      description:
          "Who picks a file the agent uploads to a page. "
          "Apart from the setting above: take uploads from the agent "
          "and leave it the rest.",
      visible: c.ref.watch(agentBrowserProvider).trustedInput,
    ),
  ),
  SettingSpec(
    id: "browserProcess",
    path: (page: _page, section: "agentBrowser"),
    weight: 50,
    title: "Browser process",
    hint: UiHint.row,
    build: (c) {
      final running = c.ref.watch(browserRunningProvider);
      final browser = c.ref.watch(agentBrowserProvider);
      return ActionController(
        c.spec,
        label: "Quit",
        description: running
            ? "Running. It quits by itself after ten idle minutes."
            : "Not running. It starts when the agent opens a page.",
        enabled: running,
        run: () async {
          unawaited(browser.close());
          return null;
        },
      );
    },
  ),
  SettingSpec(
    id: "browserData",
    path: (page: _page, section: "agentBrowser"),
    weight: 60,
    title: "Browser data",
    description:
        "The cookies, logins and history of the "
        "browser's own profile, whichever browser is picked.",
    hint: UiHint.row,
    build: (c) {
      final browser = c.ref.watch(agentBrowserProvider);
      return ActionController(
        c.spec,
        label: "Delete",
        confirm: () async => const SettingConfirm(
          title: "Delete browser data?",
          message:
              "The browser quits, and its cookies, logins, history and "
              "site data are deleted. Every site the agent signed into is "
              "signed out.",
          confirmLabel: "Delete",
          destructive: true,
        ),
        run: () async {
          try {
            await browser.clearData();
            return const SettingNotice("Browser data deleted.");
          } catch (e) {
            logFailure("browser", "deleting the profile", e);
            return SettingNotice("Could not delete browser data: $e");
          }
        },
      );
    },
  ),
  SettingSpec(
    id: "embeddedBrowser",
    path: (page: _page, section: "embedded"),
    weight: 0,
    title: "Helium",
    hint: UiHint.single,
    build: (c) {
      final downloads = c.ref.watch(embeddedBrowserDownloadsProvider);
      final installed = c.ref
          .watch(agentBrowserProvider)
          .embedded
          .installedVersion;
      final notifier = c.ref.read(embeddedBrowserDownloadsProvider.notifier);
      const id = EmbeddedBrowserDownloads.id;
      return CatalogController(
        c.spec,
        items: [
          CatalogItem(
            id: id,
            title: "Helium",
            summary:
                downloads.failures[id] ??
                (installed == null ? "Not downloaded" : "Version $installed"),
            progress: downloads.active[id],
            installed: installed != null,
            updatable: true,
          ),
        ],
        download: (id) async => notifier.install(id),
        cancel: (id) async => notifier.cancel(id),
        delete: notifier.delete,
      );
    },
  ),
];
