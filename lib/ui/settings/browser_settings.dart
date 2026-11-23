import "dart:async";

import "package:file_selector/file_selector.dart" show openFile;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/browser_settings.dart";
import "../../app/downloads/browser_downloads.dart";
import "../../app/settings/scope.dart";
import "package:entoli_chat/core/log.dart";
import "package:entoli_chat/domain/agent_browser.dart";
import "package:entoli_chat/domain/settings/keys.dart";
import "../../providers.dart";
import "package:entoli_chat/ui/widgets/busy.dart";
import "package:entoli_chat/ui/widgets/dialogs.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "scoped.dart";

const _app = AppAddress();

/// The dropdown's answer that opens the file picker rather than picking.
const _chooseBrowser = "\u0000choose";

/// Settings > Agent Browser: which browser the `browser_*` tools drive, how
/// far they may go unasked, and the embedded one to download. Drawn only
/// where [AgentBrowser.available].
class BrowserSettings extends ConsumerWidget {
  const BrowserSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final browser = ref.watch(agentBrowserProvider);
    // The browser reads its pick off disk; watching the settings is what
    // redraws the switch once it changes.
    final scope = scopeOf(ref, _app);
    return ListView(
      children: [
        const SectionHeader(
          "Agent browser",
          description:
              "A browser window the agent opens pages in, clicks and "
              "types into, for pages that need JavaScript or a login. It runs "
              "with a profile of its own, so what it logs into stays logged in "
              "and your own browser's profile is never touched.",
        ),
        // The phones' is the app's own WebView: on or off, nothing to pick.
        if (browser.inApp)
          SwitchListTile(
            title: const Text("Let the agent use a browser"),
            subtitle: const Text(
              "A WebView kept off screen. The chat's "
              "browser card shows its page.",
            ),
            value: browser.configured,
            onChanged: (on) => guarded(
              context,
              () => ref
                  .read(appSettingsProvider.notifier)
                  .setAgentBrowser(on ? webViewBrowserId : browserOffId),
            ),
          )
        else ...[
          const _BrowserPicker(),
          SwitchListTile(
            title: const Text("Show the browser window"),
            subtitle: const Text(
              "Off, it runs hidden. The agent can still "
              "open a window when it needs you to finish a check.",
            ),
            value: scope.resolve(SettingKeys.agentBrowserVisible)!,
            onChanged: (visible) => guarded(
              context,
              () => ref.read(browserPickProvider.notifier).setVisible(visible),
            ),
          ),
        ],
        const ScopedChoice(
          setting: SettingKeys.agentBrowserApproval,
          at: _app,
          title: "Before the agent acts",
          options: {
            BrowserApproval.never: "Don't ask",
            BrowserApproval.classifier: "Let the classifier decide",
            BrowserApproval.always: "Ask every time",
          },
          description:
              "Opening a page, clicking, typing and dragging. A "
              "site you have denied in a permission rule stays denied.",
        ),
        if (browser.trustedInput)
          const ScopedChoice(
            setting: SettingKeys.agentBrowserUploads,
            at: _app,
            title: "File uploads",
            options: {
              BrowserUploadPolicy.classifier: "Let the classifier decide",
              BrowserUploadPolicy.allow: "Don't ask",
              BrowserUploadPolicy.user: "I choose the file",
            },
            description:
                "Who picks a file the agent uploads to a page. "
                "Apart from the setting above: take uploads from the agent "
                "and leave it the rest.",
          ),
        const _BrowserProcess(),
        ListTile(
          title: const Text("Browser data"),
          subtitle: const Text(
            "The cookies, logins and history of the "
            "browser's own profile, whichever browser is picked.",
          ),
          trailing: OutlinedButton(
            onPressed: () => _clearData(context, browser),
            child: const Text("Delete"),
          ),
        ),
        if (!browser.inApp) ...[
          const Divider(),
          const SectionHeader(
            "Embedded browser",
            description:
                "Helium, a Chromium browser that ships with uBlock "
                "Origin: the pages the agent opens come without ads or "
                "trackers, and with fewer scripts that try to talk it into "
                "something. Downloaded from Helium's GitHub releases.",
          ),
          const _Helium(),
        ],
      ],
    );
  }

  Future<void> _clearData(BuildContext context, AgentBrowser browser) async {
    final sure = await confirm(
      context,
      title: "Delete browser data?",
      message:
          "The browser quits, and its cookies, logins, history and "
          "site data are deleted. Every site the agent signed into is "
          "signed out.",
      confirmLabel: "Delete",
      destructive: true,
    );
    if (!sure || !context.mounted) return;
    try {
      await browser.clearData();
      if (context.mounted) notify(context, "Browser data deleted.");
    } catch (e) {
      logFailure("browser", "deleting the profile", e);
      if (context.mounted) say(context, "Could not delete browser data: $e");
    }
  }
}

/// Which browser is driven: off, the embedded one, one found on the machine,
/// or one picked from the disk, which is started first to check it can be.
class _BrowserPicker extends ConsumerWidget {
  const _BrowserPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final found = ref.watch(foundBrowsersProvider).value ?? const [];
    final pick = ref.watch(browserPickProvider);
    final picked = scopeOf(ref, _app).resolve(SettingKeys.agentBrowser);
    final installed = ref.watch(agentBrowserProvider).embedded.installedVersion;
    final custom =
        picked != null &&
        picked != embeddedBrowserId &&
        !found.any((b) => b.path == picked);
    return LabelledField(
      label: "Browser",
      child: DropdownButtonFormField<String?>(
        key: ValueKey(picked),
        initialValue: picked == embeddedBrowserId && installed == null
            ? null
            : picked,
        isExpanded: true,
        decoration: InputDecoration(
          helperText: pick.verifying
              ? "Starting it to check it can be driven…"
              : picked == null
              ? "Off: the agent has no browser tools."
              : "Only Chromium-family browsers can be driven.",
          errorText: pick.problem,
          errorMaxLines: 4,
        ),
        items: [
          const DropdownMenuItem(value: null, child: Text("Off")),
          if (installed != null)
            DropdownMenuItem(
              value: embeddedBrowserId,
              child: Text("Embedded (Helium $installed)"),
            ),
          for (final found in found)
            DropdownMenuItem(value: found.path, child: Text(found.name)),
          if (custom)
            DropdownMenuItem(
              value: picked,
              child: Text(picked, overflow: TextOverflow.ellipsis),
            ),
          const DropdownMenuItem(
            value: _chooseBrowser,
            child: Text("Choose a browser…"),
          ),
        ],
        onChanged: pick.verifying
            ? null
            : (value) => guarded(context, () async {
                final picker = ref.read(browserPickProvider.notifier);
                if (value != _chooseBrowser) return picker.pick(value);
                final file = await openFile(
                  confirmButtonText: "Use this browser",
                );
                if (file != null) await picker.pickFile(file.path);
              }),
      ),
    );
  }
}

class _BrowserProcess extends ConsumerWidget {
  const _BrowserProcess();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(browserRunningProvider);
    return ListTile(
      title: const Text("Browser process"),
      subtitle: Text(
        running
            ? "Running. It quits by itself after ten idle minutes."
            : "Not running. It starts when the agent opens a page.",
      ),
      trailing: OutlinedButton(
        onPressed: running
            ? () => guarded(context, ref.read(agentBrowserProvider).close)
            : null,
        child: const Text("Quit"),
      ),
    );
  }
}

/// The embedded browser's row: its version, a download's progress, and what
/// can be done to it.
class _Helium extends ConsumerWidget {
  const _Helium();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const id = EmbeddedBrowserDownloads.id;
    final downloads = ref.watch(embeddedBrowserDownloadsProvider);
    final notifier = ref.read(embeddedBrowserDownloadsProvider.notifier);
    final installed = ref.watch(agentBrowserProvider).embedded.installedVersion;
    final progress = downloads.active[id];
    final failure = downloads.failures[id];
    return ListTile(
      title: const Text("Helium"),
      subtitle: progress != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  progress.unpacking
                      ? "Installing…"
                      : progress.total > 0
                      ? "Downloading · ${progress.received >> 20} of "
                            "${progress.total >> 20} MB"
                      : "Downloading…",
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: progress.bar),
              ],
            )
          : Text(
              failure ??
                  (installed == null ? "Not downloaded" : "Version $installed"),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (progress != null)
            TextButton(
              onPressed: () => notifier.cancel(id),
              child: const Text("Cancel"),
            )
          else ...[
            if (installed != null)
              IconButton(
                tooltip: "Delete",
                icon: const Icon(Icons.delete_outline),
                onPressed: () => guarded(context, () => notifier.delete(id)),
              ),
            FilledButton.tonal(
              onPressed: () => notifier.install(id),
              child: Text(installed == null ? "Download" : "Update"),
            ),
          ],
        ],
      ),
    );
  }
}
